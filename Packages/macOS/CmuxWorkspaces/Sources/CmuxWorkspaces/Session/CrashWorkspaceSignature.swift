public import Foundation

/// Cached identity and restore evidence for one workspace generation.
public struct CrashWorkspaceSignature: Sendable {
    let stableID: UUID?
    let workspaceID: UUID?
    let checkpointIDs: Set<String>
    let nonAgentPanelIDs: Set<UUID>
    let title: String?
    let description: String?
    let groupID: UUID?
    let directory: String
    let dock: CrashDockSignature?
    /// The amount of useful restore metadata in this workspace.
    public let fidelityScore: Int

    /// Builds matching evidence once, before comparing workspace generations.
    /// - Parameters:
    ///   - stableID: Stable workspace identity, when recorded.
    ///   - workspaceID: Persisted runtime identity, when recorded.
    ///   - checkpointIDs: Agent checkpoints from the workspace and its dock.
    ///   - title: Custom workspace title; blank titles cannot identify a workspace.
    ///   - description: Custom description, which must match for title fallback.
    ///   - groupID: Persisted group membership; differing memberships stay separate.
    ///   - directory: Standardized workspace path; empty paths cannot identify a workspace.
    ///   - dock: Dock identity, or nil when no dock was persisted.
    ///   - fidelityScore: Restore metadata score used when checkpoint sets are equal.
    ///   - nonAgentPanelIDs: Persisted panels without agent checkpoint identity.
    public nonisolated init(
        stableID: UUID?, workspaceID: UUID?, checkpointIDs: Set<String>,
        title: String?, description: String?, groupID: UUID?, directory: String,
        dock: CrashDockSignature?, fidelityScore: Int, nonAgentPanelIDs: Set<UUID> = []
    ) {
        self.stableID = stableID
        self.workspaceID = workspaceID
        self.checkpointIDs = checkpointIDs
        self.nonAgentPanelIDs = nonAgentPanelIDs
        self.title = title
        self.description = description
        self.groupID = groupID
        self.directory = directory
        self.dock = dock
        self.fidelityScore = fidelityScore
    }

    /// A whole copy may replace another only if it covers every panel identity.
    nonisolated func canMerge(with other: Self) -> Bool {
        groupID == other.groupID && dock == other.dock
            && (containsPanels(of: other) || other.containsPanels(of: self))
    }

    nonisolated func isPreferred(over other: Self) -> Bool {
        if checkpointIDs != other.checkpointIDs || nonAgentPanelIDs != other.nonAgentPanelIDs {
            return containsPanels(of: other)
        }
        return fidelityScore > other.fidelityScore
    }

    private nonisolated func containsPanels(of other: Self) -> Bool {
        checkpointIDs.isSuperset(of: other.checkpointIDs)
            && nonAgentPanelIDs.isSuperset(of: other.nonAgentPanelIDs)
    }
}
