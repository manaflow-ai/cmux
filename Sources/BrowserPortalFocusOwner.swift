import Foundation

/// Identifies which browser-owned layer currently owns keyboard focus.
///
/// Portal views are siblings rather than descendants of the hosted page, so
/// responder ownership must be resolved from the slot's structure. Callers
/// that want to capture page shortcuts may proceed only for ``page``; every
/// chrome case deliberately fails closed.
enum BrowserPortalFocusOwner {
    case page(CmuxWebView)
    case search(panelId: UUID)
    case designComposer
    case omnibarSuggestions
    case inspector
    case otherChrome
}
