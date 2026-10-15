public import Foundation

/// A page's request to open a new page (`target=_blank`, `window.open`,
/// Command-click).
public struct BrowserPageOpenRequest: Equatable, Hashable, Sendable {
    /// What the page asked for.
    public enum Placement: Equatable, Hashable, Sendable {
        /// A new foreground tab.
        case foregroundTab
        /// A new background tab (Command-click).
        case backgroundTab
        /// A popup window with optional requested content size.
        case popup(width: Double?, height: Double?)
    }

    /// The URL to open, if known.
    public var url: URL?
    /// What the page asked for.
    public var placement: Placement
    /// `true` when user input started it; popups without a gesture are usually blocked.
    public var isUserGesture: Bool

    /// Creates an open request.
    /// - Parameters:
    ///   - url: The URL to open.
    ///   - placement: What the page asked for.
    ///   - isUserGesture: Whether user input started it.
    public init(url: URL?, placement: Placement, isUserGesture: Bool) {
        self.url = url
        self.placement = placement
        self.isUserGesture = isUserGesture
    }
}
