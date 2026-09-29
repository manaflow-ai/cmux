import AppKit
import SwiftUI

/// Hosts the panel-owned ``AcpmuxChatPaneView`` in the SwiftUI pane tree.
///
/// The pane view lives on the panel, so SwiftUI re-creating this representable (tab
/// switches, split changes) keeps scroll position, expansion state, and the composer draft.
struct AcpmuxChatPaneRepresentable: NSViewRepresentable {
    let panel: AgentSessionPanel
    let theme: AcpmuxChatTheme

    func makeNSView(context: Context) -> AcpmuxChatPaneContainerView {
        let container = AcpmuxChatPaneContainerView(frame: .zero)
        container.embed(panel.chatPaneView(theme: theme))
        return container
    }

    func updateNSView(_ container: AcpmuxChatPaneContainerView, context: Context) {
        let pane = panel.chatPaneView(theme: theme)
        pane.setTheme(theme)
        container.embed(pane)
    }
}

/// A plain container that keeps the embedded pane sized to its bounds.
final class AcpmuxChatPaneContainerView: NSView {
    func embed(_ pane: NSView) {
        guard pane.superview !== self else { return }
        pane.removeFromSuperview()
        pane.frame = bounds
        pane.autoresizingMask = [.width, .height]
        addSubview(pane)
    }
}
