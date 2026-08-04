/// Deterministic aggregate plus ordered items for one completed turn.
public struct TranscriptActivitySummary: Hashable, Sendable {
    /// Number of edit-like events.
    public let editedFileCount: Int
    /// Number of read-like tool events.
    public let readFileCount: Int
    /// Whether a search-like tool ran.
    public let searchedCode: Bool
    /// Whether a list-like tool ran.
    public let listedFiles: Bool
    /// Number of tool or command events.
    public let commandCount: Int
    /// Number of other non-prose events.
    public let eventCount: Int
    /// Number of failed activities in this turn.
    public let failedCount: Int
    /// Ordered activity items with stable source identities.
    public let items: [TranscriptActivityItem]

    /// Creates a completed activity summary.
    /// - Parameters:
    ///   - editedFileCount: Number of edit-like events.
    ///   - readFileCount: Number of read-like tool events.
    ///   - searchedCode: Whether a search-like tool ran.
    ///   - listedFiles: Whether a list-like tool ran.
    ///   - commandCount: Number of tool or command events.
    ///   - eventCount: Number of other non-prose events.
    ///   - failedCount: Number of failed activities.
    ///   - items: Ordered stable activity items.
    public init(
        editedFileCount: Int,
        readFileCount: Int,
        searchedCode: Bool,
        listedFiles: Bool,
        commandCount: Int,
        eventCount: Int,
        failedCount: Int = 0,
        items: [TranscriptActivityItem]
    ) {
        self.editedFileCount = editedFileCount
        self.readFileCount = readFileCount
        self.searchedCode = searchedCode
        self.listedFiles = listedFiles
        self.commandCount = commandCount
        self.eventCount = eventCount
        self.failedCount = failedCount
        self.items = items
    }
}
