#!/usr/bin/env bash
# Lowers the iOS launcher's minimum to iOS 15 (run from the repo root).
set -euo pipefail
cd packaging/ios
L=Launcher

# 1. Deployment target
sed -i.bak 's/iOS: "16.0"/iOS: "15.0"/; s/IPHONEOS_DEPLOYMENT_TARGET: 16.0/IPHONEOS_DEPLOYMENT_TARGET: 15.0/' project.yml
sed -i.bak 's|<string>16.0</string>|<string>15.0</string>|' GameInfo.plist
grep -q 'iOS: "15.0"' project.yml

# 2. Compatibility helpers
cat > $L/Compat.swift <<'EOF'
import SwiftUI
import UIKit

/// iOS 15 stand-ins for the iOS 16 APIs the launcher uses.
struct CompatNavigationStack<Content: View>: View {
    let content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }
    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack { content() }
        } else {
            NavigationView { content() }.navigationViewStyle(.stack)
        }
    }
}

enum CompatDetent { case medium, large, mediumLarge }

extension View {
    @ViewBuilder func compatDetents(_ kind: CompatDetent) -> some View {
        if #available(iOS 16.0, *) {
            switch kind {
            case .medium: self.presentationDetents([.medium])
            case .large: self.presentationDetents([.large])
            case .mediumLarge: self.presentationDetents([.medium, .large])
            }
        } else {
            self
        }
    }

    @ViewBuilder func compatHideNavBarBackground() -> some View {
        if #available(iOS 16.0, *) { self.toolbarBackground(.hidden, for: .navigationBar) } else { self }
    }

    @ViewBuilder func compatDestination<D: View>(isPresented: Binding<Bool>,
                                                 @ViewBuilder _ destination: @escaping () -> D) -> some View {
        if #available(iOS 16.0, *) {
            self.navigationDestination(isPresented: isPresented, destination: destination)
        } else {
            self.background(NavigationLink(destination: destination(), isActive: isPresented) { EmptyView() }.hidden())
        }
    }
}

struct CompatShareLink<Label: View>: View {
    let url: URL
    let label: () -> Label
    init(item: URL, @ViewBuilder label: @escaping () -> Label) { self.url = item; self.label = label }
    var body: some View {
        if #available(iOS 16.0, *) {
            ShareLink(item: url, label: label)
        } else {
            Button {
                let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                if let top = gameViewController() {
                    sheet.popoverPresentationController?.sourceView = top.view
                    top.present(sheet, animated: true)
                }
            } label: { label() }
        }
    }
}
EOF

# 3. Call sites
sed -i.bak 's/NavigationStack {/CompatNavigationStack {/' $L/GameFiles.swift $L/Worlds.swift $L/TouchControls.swift $L/HomeView.swift
sed -i.bak 's/ShareLink(item:/CompatShareLink(item:/' $L/Gallery.swift
sed -i.bak 's/\.presentationDetents(\[\.large\])/.compatDetents(.large)/' $L/Worlds.swift $L/Settings.swift
sed -i.bak 's/\.presentationDetents(\[\.medium\])/.compatDetents(.medium)/' $L/Servers.swift
sed -i.bak 's/\.presentationDetents(\[\.medium, \.large\])/.compatDetents(.mediumLarge)/' $L/HomeView.swift
sed -i.bak 's/\.presentationDragIndicator(\.visible)/.compatDragIndicator()/' $L/Worlds.swift
sed -i.bak 's/\.toolbarBackground(\.hidden, for: \.navigationBar)/.compatHideNavBarBackground()/' $L/HomeView.swift
sed -i.bak 's/\.navigationDestination(isPresented:/.compatDestination(isPresented:/' $L/HomeView.swift
sed -i.bak 's/\.tracking(/.compatTracking(/' $L/DownloadView.swift $L/HomeView.swift
sed -i.bak 's/\.semibold))\.underline()/.semibold)).compatUnderline()/' $L/HomeView.swift
# iPad split view is iOS 16: older systems use the tab layout.
sed -i.bak 's/if sizeClass == \.regular {/if sizeClass == .regular, #available(iOS 16.0, *) {/' $L/HomeView.swift

# 4. Orientation: iOS 16 scene geometry API, with an iOS 15 fallback.
python3 - <<'PY'
p = "Launcher/Present.swift"
s = open(p).read()
start = s.index("func turn(_ scene")
end = s.index("/// The view controller of winit's window")
new = '''func turn(_ scene: UIWindowScene?, to orientations: UIInterfaceOrientationMask) {
    guard let scene else { return }
    if #available(iOS 16.0, *) {
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            var top = window.rootViewController
            while let next = top?.presentedViewController {
                top = next
            }
            top?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { error in
            NSLog("Horizon orientation request failed: %@", error.localizedDescription)
        }
    } else if orientations == .portrait {
        UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()
    } else {
        UIViewController.attemptRotationToDeviceOrientation()
    }
}

'''
open(p, "w").write(s[:start] + new + s[end:])
PY
find . -name "*.bak" -delete
echo "iOS 15 patch applied"
