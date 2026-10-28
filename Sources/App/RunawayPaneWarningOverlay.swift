import AppKit
import SwiftUI

/// Hosts the runaway-terminal banner at the top of a window's workspace
/// content. Terminal and browser portals are AppKit siblings above the
/// SwiftUI content, so a SwiftUI overlay would draw underneath them; like the
/// cloud pane failure card, the banner is a native sibling above the portals
/// and this view only anchors its geometry.
struct RunawayPaneWarningOverlay: NSViewRepresentable {
    let warning: RunawayPaneWarning?
    let onStop: (RunawayPaneWarning) -> Void
    let onDismiss: (RunawayPaneWarning) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.coordinator = context.coordinator
        context.coordinator.anchor = view
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        context.coordinator.update(
            warning: warning,
            layoutDirection: context.environment.layoutDirection,
            colorScheme: context.environment.colorScheme,
            onStop: onStop,
            onDismiss: onDismiss
        )
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
        view.coordinator = nil
        coordinator.removeCard()
    }
}
