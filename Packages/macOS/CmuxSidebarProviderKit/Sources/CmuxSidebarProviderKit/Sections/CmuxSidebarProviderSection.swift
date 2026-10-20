import Foundation

/// Rendered section with tree metadata and concrete rows.
public struct CmuxSidebarProviderSection: Identifiable, Codable, Equatable, Sendable {
    /// Stable section id.
    public var id: String
    /// Tree/list section metadata.
    public var treeSection: CmuxSidebarProviderTreeSection
    /// Rows rendered in this section.
    public var rows: [CmuxSidebarProviderRow]

    /// Creates a provider section.
    public init(
        id: String,
        treeSection: CmuxSidebarProviderTreeSection,
        rows: [CmuxSidebarProviderRow]
    ) {
        self.id = id
        self.treeSection = treeSection
        self.rows = rows
    }
}
