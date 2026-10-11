public import AppKit
public import Foundation

/// Where a page's developer tools show (the dock side).
public nonisolated enum BrowserDevToolsDock: String, Hashable, Sendable, CaseIterable {
    /// Below the page, inside the pane.
    case bottom
    /// Right of the page, inside the pane.
    case right
    /// Left of the page, inside the pane.
    case left
    /// A separate window.
    case window

    public var isDocked: Bool { self != .window }

    /// Beside the page (the divider runs vertically).
    public var isSide: Bool { self == .left || self == .right }
}

/// A developer tools request (Cmd-Opt-I, Cmd-Opt-J, Cmd-Opt-C).
public nonisolated enum BrowserDevToolsCommand: Hashable, Sendable {
    /// Open when closed, close when open (Cmd-Opt-I).
    case toggle
    /// Open, or focus the open tools.
    case show
    /// Open on the Console panel (Cmd-Opt-J).
    case console
    /// Pick an element in the page to inspect (Cmd-Opt-C).
    case inspectElement
    case close
    /// Move the tools; reopens them when they move into or out of a window.
    case dock(BrowserDevToolsDock)
}

/// What the tools of one page look like now.
public nonisolated struct BrowserDevToolsState: Hashable, Sendable {
    public var isOpen: Bool
    public var dock: BrowserDevToolsDock

    public init(isOpen: Bool = false, dock: BrowserDevToolsDock = .bottom) {
        self.isOpen = isOpen
        self.dock = dock
    }
}
