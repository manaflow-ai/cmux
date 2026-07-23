import Foundation

/// The logical agent session and process roots currently assigned to a Computer Use driver session.
struct ComputerUseLiveDriverSession: Equatable, Sendable {
    let workspaceID: UUID
    let surfaceID: UUID
    let logicalSessionID: String
    let rootProcessIdentities: Set<AgentPIDProcessIdentity>

    init?(
        workspaceID: UUID,
        surfaceID: UUID,
        entry: RestorableAgentSessionIndex.Entry
    ) {
        let rootProcessIdentities = Set(entry.agentProcessIdentities.values)
        guard !rootProcessIdentities.isEmpty else { return nil }

        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.logicalSessionID = Self.logicalSessionID(
            snapshot: entry.snapshot,
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
        self.rootProcessIdentities = rootProcessIdentities
    }

    init(
        workspaceID: UUID,
        surfaceID: UUID,
        logicalSessionID: String,
        rootProcessIdentities: Set<AgentPIDProcessIdentity>
    ) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.logicalSessionID = logicalSessionID
        self.rootProcessIdentities = rootProcessIdentities
    }

    static func logicalSessionID(
        snapshot: SessionRestorableAgentSnapshot,
        workspaceID: UUID,
        surfaceID: UUID
    ) -> String {
        [
            snapshot.kind.rawValue,
            snapshot.sessionId,
            workspaceID.uuidString,
            surfaceID.uuidString,
        ].joined(separator: "|")
    }

    /// Revalidates a scanned action against the current generation of the same
    /// logical agent session immediately before cmux fronts its target.
    func authorizes(
        state: ComputerUseDriverState,
        currentSession: ComputerUseLiveDriverSession
    ) -> Bool {
        guard logicalSessionID == currentSession.logicalSessionID else {
            return false
        }
        return state.belongsToProcessTree(
            rootProcessIdentities: currentSession.rootProcessIdentities
        )
    }
}
