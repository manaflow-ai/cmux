public import Foundation

/// One keyed markdown metadata block shown under a workspace in the sidebar.
public struct SidebarMetadataBlock: Equatable, Sendable {
    /// Stable key identifying the block (last write per key wins).
    public let key: String
    /// The markdown content.
    public let markdown: String
    /// Sort priority (higher sorts first).
    public let priority: Int
    /// When the block was reported.
    public let timestamp: Date

    /// Creates a metadata block.
    public init(key: String, markdown: String, priority: Int, timestamp: Date) {
        self.key = key
        self.markdown = markdown
        self.priority = priority
        self.timestamp = timestamp
    }
}
