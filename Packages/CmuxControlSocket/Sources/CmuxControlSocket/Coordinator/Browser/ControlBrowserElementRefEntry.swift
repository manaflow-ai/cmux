public import Foundation

/// One minted `@eN` element handle (was the controller-private
/// `V2BrowserElementRefEntry`): the CSS selector a `browser.find.*` call (or a
/// snapshot) resolved, pinned to the browser surface it was resolved on so a
/// stale ref can never act on another surface's DOM.
public struct ControlBrowserElementRefEntry: Sendable, Equatable {
    /// The browser surface the selector was resolved on.
    public let surfaceID: UUID
    /// The CSS selector the `@eN` ref expands to.
    public let selector: String

    /// Creates an element-ref entry.
    ///
    /// - Parameters:
    ///   - surfaceID: The browser surface the selector was resolved on.
    ///   - selector: The CSS selector the ref expands to.
    public init(surfaceID: UUID, selector: String) {
        self.surfaceID = surfaceID
        self.selector = selector
    }
}
