public import Foundation

/// One workspace's searchable text, prepared for repeated matching.
///
/// Built once per corpus revision by the owner of the workspace list and
/// re-scored on every keystroke. Carries only value types: no `Workspace`
/// reference crosses into the filter, so scoring stays pure and testable.
public struct SidebarFilterCandidate: Sendable, Identifiable {
    /// The workspace this candidate represents.
    public let id: UUID
    /// The group the workspace belongs to, if any.
    public let groupId: UUID?
    /// Whether this workspace is its group's anchor (rendered as the header).
    public let isGroupAnchor: Bool
    /// Every prepared field this workspace can be matched on.
    public let fields: [SidebarFilterCandidateField]

    /// Creates a candidate for one workspace.
    ///
    /// - Parameters:
    ///   - id: The workspace id.
    ///   - groupId: The workspace's group, or nil when ungrouped.
    ///   - isGroupAnchor: Whether the workspace renders as its group's header.
    ///   - fields: Prepared searchable fields; empty fields should be omitted
    ///     by the caller rather than passed as empty strings.
    public init(
        id: UUID,
        groupId: UUID? = nil,
        isGroupAnchor: Bool = false,
        fields: [SidebarFilterCandidateField]
    ) {
        self.id = id
        self.groupId = groupId
        self.isGroupAnchor = isGroupAnchor
        self.fields = fields
    }
}
