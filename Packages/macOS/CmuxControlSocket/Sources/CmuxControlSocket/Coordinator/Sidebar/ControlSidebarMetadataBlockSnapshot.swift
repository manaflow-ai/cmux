internal import Foundation

/// A Sendable snapshot of one sidebar metadata block, in display order, for
/// the v1 `list_meta_blocks` / `sidebar_state` line formatting.
public struct ControlSidebarMetadataBlockSnapshot: Sendable, Equatable {
    /// The block key.
    public let key: String
    /// The raw markdown content.
    public let markdown: String
    /// The display priority (0 omitted from the listing line).
    public let priority: Int

    /// Creates a snapshot.
    ///
    /// - Parameters:
    ///   - key: The block key.
    ///   - markdown: The raw markdown content.
    ///   - priority: The display priority.
    public init(key: String, markdown: String, priority: Int) {
        self.key = key
        self.markdown = markdown
        self.priority = priority
    }
}
