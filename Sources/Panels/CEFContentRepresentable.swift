import SwiftUI

/// SwiftUI bridge that reparents a CEF browser's embeddable AppKit view into a cmux pane.
struct CEFContentRepresentable: NSViewRepresentable {
    let panel: CEFBrowserPanel
    let revision: Int
    let onRequestPanelFocus: () -> Void

    func makeNSView(context: Context) -> CEFReparentContainerView {
        let container = CEFReparentContainerView()
        container.cefPanel = panel
        container.onRequestPanelFocus = onRequestPanelFocus
        return container
    }

    func updateNSView(_ container: CEFReparentContainerView, context: Context) {
        _ = revision
        container.cefPanel = panel
        container.onRequestPanelFocus = onRequestPanelFocus
        container.adoptEmbeddableView(panel.embeddableView)
    }

    static func dismantleNSView(_ container: CEFReparentContainerView, coordinator: ()) {
        container.detachEmbeddableView()
    }
}
