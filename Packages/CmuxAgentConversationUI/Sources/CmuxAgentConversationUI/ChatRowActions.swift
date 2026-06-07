import Foundation

/// A value-typed bundle of closures handed to chat rows in place of a store
/// reference.
///
/// Rows below the `LazyVStack` boundary must not hold an `@Observable` /
/// `ObservableObject` reference (see the repo's snapshot-boundary rule), so
/// every capability a row needs is a closure captured above the boundary. The
/// closures are stable, so excluding them from a row's `Equatable` check keeps
/// the layout cache from thrashing on unrelated model changes.
@MainActor
public struct ChatRowActions {
    /// Whether the tool-call row with the given call id is currently expanded.
    public let isToolCallExpanded: (String) -> Bool

    /// Toggles the expanded/collapsed state of a tool-call row by call id.
    public let toggleToolCall: (String) -> Void

    /// Copies the given text to the pasteboard.
    public let copyText: (String) -> Void

    /// Creates a chat-row action bundle.
    ///
    /// - Parameters:
    ///   - isToolCallExpanded: Returns whether a tool-call row is expanded.
    ///   - toggleToolCall: Toggles a tool-call row's expansion by call id.
    ///   - copyText: Copies text to the pasteboard.
    public init(
        isToolCallExpanded: @escaping (String) -> Bool,
        toggleToolCall: @escaping (String) -> Void,
        copyText: @escaping (String) -> Void
    ) {
        self.isToolCallExpanded = isToolCallExpanded
        self.toggleToolCall = toggleToolCall
        self.copyText = copyText
    }
}
