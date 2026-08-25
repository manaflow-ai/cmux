import AppKit
import SwiftUI

struct MacAppSurfaceRepresentable: NSViewRepresentable {
    let panel: MacAppPanel
    let isFocused: Bool
    let allowsPointerInput: Bool
    let onRequestPanelFocus: () -> Void

    func makeNSView(context: Context) -> MacAppSurfaceView {
        let view = MacAppSurfaceView()
        panel.setSurfaceView(view)
        view.onFocus = onRequestPanelFocus
        view.update(
            image: panel.latestImage,
            descriptor: panel.selectedWindow,
            acceptsInput: isFocused && allowsPointerInput && !panel.requiresAccessibilityPermission
        )
        return view
    }

    func updateNSView(_ view: MacAppSurfaceView, context: Context) {
        panel.setSurfaceView(view)
        view.onFocus = onRequestPanelFocus
        view.update(
            image: panel.latestImage,
            descriptor: panel.selectedWindow,
            acceptsInput: isFocused && allowsPointerInput && !panel.requiresAccessibilityPermission
        )
    }

    static func dismantleNSView(_ view: MacAppSurfaceView, coordinator: ()) {
        view.onFocus = nil
    }
}
