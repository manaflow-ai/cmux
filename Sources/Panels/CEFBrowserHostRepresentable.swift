import CEFKit
import SwiftUI

/// Bridges ``CEFBrowserHostView`` into the CEF panel's SwiftUI hierarchy.
struct CEFBrowserHostRepresentable: NSViewRepresentable {
    let hostView: CEFBrowserHostView
    let ownerID: UUID
    let suggestions: BrowserPortalOmnibarSuggestionsConfiguration?
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> CEFBrowserHostCoordinator {
        CEFBrowserHostCoordinator(
            containerView: hostView.containerView,
            presentationOwnerID: ownerID,
            onRequestPanelFocus: onRequestPanelFocus
        )
    }

    func makeNSView(context: Context) -> CEFBrowserHostView {
        hostView
    }

    func updateNSView(_ nsView: CEFBrowserHostView, context: Context) {
        nsView.setOmnibarSuggestions(suggestions, ownerID: ownerID)
    }

    static func dismantleNSView(
        _ nsView: CEFBrowserHostView,
        coordinator: CEFBrowserHostCoordinator
    ) {
        nsView.clearOmnibarSuggestions(ownerID: coordinator.presentationOwnerID)
    }
}
