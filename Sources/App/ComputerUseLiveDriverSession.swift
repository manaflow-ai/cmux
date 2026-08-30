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
        let recordedProcessIdentities = Set(entry.agentProcessIdentities.values)
        let rootProcessIdentities: Set<AgentPIDProcessIdentity>
        if recordedProcessIdentities.isEmpty {
            rootProcessIdentities = Set(entry.agentProcessIDs.compactMap { processID in
                guard processID > 0, processID <= Int(Int32.max) else { return nil }
                return AgentPIDProcessIdentity(pid: pid_t(processID))
            })
        } else {
            rootProcessIdentities = recordedProcessIdentities
        }
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
        state: ComputerUseCuaState,
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
