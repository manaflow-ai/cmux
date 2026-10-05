import Foundation

/// Accepted workspace context owned and persisted by CMUX.
public struct CmuxSidebarWorkspaceContext: Codable, Equatable, Sendable {
    /// Monotonic native revision required by every context mutation.
    public var revision: UInt64
    /// Accepted classification tags, with manual selections preserved.
    public var tags: [CmuxSidebarContextTag]
    /// Previous workspace display names retained for discovery.
    public var aliases: [String]
    /// Accepted concise project summary.
    public var summary: String?
    /// Stable automatic tag IDs suppressed until explicitly cleared.
    public var rejectedAutomaticTagIDs: [String]
    /// Latest analyzed proposal, which is separate from accepted metadata.
    public var analyzedProposal: CmuxSidebarWorkspaceContextProposal?
    /// Whether native one-step undo is available at this revision.
    public var canUndo: Bool

    /// Creates a workspace-context value.
    /// - Parameters:
    ///   - revision: Current native revision.
    ///   - tags: Accepted tags.
    ///   - aliases: Former display names.
    ///   - summary: Accepted summary.
    ///   - rejectedAutomaticTagIDs: Suppressed automatic tag identifiers.
    ///   - analyzedProposal: Latest retained analysis.
    ///   - canUndo: Whether the host retains a reversible change.
    public init(revision: UInt64 = 0, tags: [CmuxSidebarContextTag] = [], aliases: [String] = [], summary: String? = nil, rejectedAutomaticTagIDs: [String] = [], analyzedProposal: CmuxSidebarWorkspaceContextProposal? = nil, canUndo: Bool = false) {
        self.revision = revision
        self.tags = tags
        self.aliases = aliases
        self.summary = summary
        self.rejectedAutomaticTagIDs = rejectedAutomaticTagIDs
        self.analyzedProposal = analyzedProposal
        self.canUndo = canUndo
    }
}
