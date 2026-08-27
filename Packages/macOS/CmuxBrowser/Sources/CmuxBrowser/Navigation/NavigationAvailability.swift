public import Foundation

/// The resolved back/forward availability for a browser surface.
///
/// Combines the live WebKit `canGoBack`/`canGoForward` flags with any restored
/// session-history stacks. A surface can go back either because WebKit's native
/// back-forward list has a prior entry or because a restored back stack still
/// holds replayable URLs; the same holds symmetrically for forward.
public struct NavigationAvailability: Sendable, Equatable {
    /// Whether back navigation is possible from the current entry.
    public var canGoBack: Bool

    /// Whether forward navigation is possible from the current entry.
    public var canGoForward: Bool

    /// Creates an availability value.
    public init(canGoBack: Bool, canGoForward: Bool) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }
}
