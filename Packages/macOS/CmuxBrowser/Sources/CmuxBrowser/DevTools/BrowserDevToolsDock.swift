import Foundation

/// Where a page's developer tools show.
///
/// Chromium pages dock their DevTools inside the cmux pane (bottom, left or right of the page)
/// or in a separate window. WebKit's inspector maps `attached` to ``bottom`` and `detached` to
/// ``window``.
public enum BrowserDevToolsDock: String, Hashable, Sendable, CaseIterable {
    /// Below the page, inside the pane.
    case bottom
    /// Right of the page, inside the pane.
    case right
    /// Left of the page, inside the pane.
    case left
    /// A separate window.
    case window

    /// Whether the tools share the pane with the page.
    public var isDocked: Bool { self != .window }

    /// Whether the tools sit beside the page, so the divider runs vertically.
    public var isSide: Bool { self == .left || self == .right }

    /// The dock for the side value the cmux Chromium fork reports when the user picks a dock
    /// side in the DevTools frontend menu (`CMUX_DEVTOOLS_DOCK_SIDE`).
    /// - Parameter forkSide: `0` undocked, `1` left, `2` bottom, `3` right.
    /// - Returns: The dock, or `nil` for a side cmux panes do not offer.
    public init?(forkSide: Int) {
        switch forkSide {
        case 0: self = .window
        case 1: self = .left
        case 2: self = .bottom
        case 3: self = .right
        default: return nil
        }
    }
}
