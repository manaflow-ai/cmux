import Foundation

/// Reduces a complete list of parsed transcript messages to navigable
/// user-turn summaries in one call.
public struct ChatOutlineBuilder: Sendable {
    /// Creates an outline builder.
    public init() {}

    /// Builds one entry per user prompt from parsed transcript messages.
    ///
    /// - Parameter messages: Messages in any order.
    /// - Returns: Entries in transcript order.
    public func entries(from messages: [ChatMessage]) -> [ChatOutlineEntry] {
        var accumulator = ChatOutlineAccumulator()
        accumulator.ingest(messages.sorted { $0.seq < $1.seq })
        return accumulator.entries
    }
}
