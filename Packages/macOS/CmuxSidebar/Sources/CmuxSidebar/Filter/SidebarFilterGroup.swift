public import CmuxFoundation
public import Foundation

/// One workspace group's searchable name plus the membership the filter needs
/// to decide whether the group's header survives filtering.
public struct SidebarFilterGroup: Sendable, Identifiable {
    /// The group id.
    public let id: UUID
    /// The workspace rendered as this group's header row.
    public let anchorWorkspaceId: UUID
    /// The group's display name.
    public let name: String
    /// The normalized, pre-segmented group name.
    public let prepared: FuzzyMatcher.PreparedCandidateText

    /// Creates a searchable group.
    ///
    /// - Parameters:
    ///   - id: The group id.
    ///   - anchorWorkspaceId: The workspace whose row is the group header.
    ///   - name: The group's display name.
    public init(id: UUID, anchorWorkspaceId: UUID, name: String) {
        self.id = id
        self.anchorWorkspaceId = anchorWorkspaceId
        self.name = name
        self.prepared = FuzzyMatcher.PreparedCandidateText(
            normalizedText: FuzzyMatcher.normalizeForSearch(name)
        )
    }
}
