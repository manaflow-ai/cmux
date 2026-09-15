import Foundation

/// The transient title and loading presentation for one Codex tab.
public struct CodexTabTitlePresentation: Equatable, Sendable {
    /// The title string presented by the tab bar.
    public let title: String
    /// Whether the tab bar should show its existing indeterminate indicator.
    public let isAnimating: Bool

    /// Creates a tab presentation.
    ///
    /// - Parameters:
    ///   - title: The title presented by the tab bar.
    ///   - isAnimating: Whether the tab bar should show its indeterminate indicator.
    public init(title: String, isAnimating: Bool) {
        self.title = title
        self.isAnimating = isAnimating
    }
}
