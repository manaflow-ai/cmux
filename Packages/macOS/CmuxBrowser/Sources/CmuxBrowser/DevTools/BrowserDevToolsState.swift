import Foundation

/// What one page's developer tools look like now.
public struct BrowserDevToolsState: Hashable, Sendable {
    /// Whether the tools are open.
    public var isOpen: Bool
    /// Where the tools are, or where they open next while closed.
    public var dock: BrowserDevToolsDock

    /// Creates a state value.
    /// - Parameters:
    ///   - isOpen: Whether the tools are open. Defaults to closed.
    ///   - dock: The dock side. Defaults to ``BrowserDevToolsDock/bottom``, Classic's attached
    ///     inspector position.
    public init(isOpen: Bool = false, dock: BrowserDevToolsDock = .bottom) {
        self.isOpen = isOpen
        self.dock = dock
    }
}
