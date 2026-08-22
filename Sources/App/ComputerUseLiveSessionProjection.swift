import Foundation

/// Tracks the last agent-turn completion for each stable Computer Use driver.
///
/// The MCP proxy intentionally remains alive across Codex turns. Its last
/// authenticated state file therefore outlives the turn that produced it. A
/// completion cutoff lets UI consumers retire that state without tombstoning
/// the proxy, while a later action naturally becomes eligible again.
@MainActor
final class ComputerUseActivityLifecycle {
    private var completionCutoffsByDriverSessionID: [String: Date] = [:]

    func recordCompletion(
        driverSessionID: String,
        receivedAt: Date
    ) {
        let previous = completionCutoffsByDriverSessionID[driverSessionID]
            ?? .distantPast
        completionCutoffsByDriverSessionID[driverSessionID] = max(
            previous,
            receivedAt
        )
    }

    func completionCutoffs() -> [String: Date] {
        completionCutoffsByDriverSessionID
    }

    nonisolated static func isDisplayEligible(
        driverSessionID: String,
        lastActionAt: Date,
        completionCutoffs: [String: Date]
    ) -> Bool {
        guard let cutoff = completionCutoffs[driverSessionID] else {
            return true
        }
        return lastActionAt > cutoff
    }
}

/// Projects one resilient set of live Computer Use sessions for every UI consumer.
///
/// The shared agent index is rebuilt from several asynchronous process and hook
/// sources. A refresh can briefly omit a still-running agent even though its
/// generation-validated root process and Computer Use proxy remain alive. This
/// projection retains that last authorized session through the bookkeeping gap,
/// then removes it as soon as every recorded root generation has exited.
@MainActor
final class ComputerUseLiveSessionProjection {
    typealias LiveEntry = (
        panelKey: RestorableAgentSessionIndex.PanelKey,
        entry: RestorableAgentSessionIndex.Entry
    )

    private struct Record {
        let session: ComputerUseLiveDriverSession
        let kind: RestorableAgentKind
        let agentSessionID: String
    }

    private let liveEntries: @MainActor () -> [LiveEntry]
    private let scheduleRefreshIfStaleAction: @MainActor () -> Void
    private let processIdentityIsAlive:
        @MainActor (AgentPIDProcessIdentity) -> Bool
    private var recordsByDriverSessionID: [String: Record] = [:]

    convenience init(liveAgentIndex: SharedLiveAgentIndex) {
        self.init(
            liveEntries: {
                liveAgentIndex.index?.liveEntries() ?? []
            },
            scheduleRefreshIfStale: {
                liveAgentIndex.scheduleRefreshIfStale()
            }
        )
    }

    init(
        liveEntries: @escaping @MainActor () -> [LiveEntry],
        scheduleRefreshIfStale:
            @escaping @MainActor () -> Void,
        processIdentityIsAlive:
            @escaping @MainActor (AgentPIDProcessIdentity) -> Bool = {
                AgentPIDProcessIdentity(pid: $0.pid) == $0
            }
    ) {
        self.liveEntries = liveEntries
        self.scheduleRefreshIfStaleAction = scheduleRefreshIfStale
        self.processIdentityIsAlive = processIdentityIsAlive
    }

    func scheduleRefreshIfStale() {
        scheduleRefreshIfStaleAction()
    }

    func sessionsByDriverSessionID() -> [String: ComputerUseLiveDriverSession] {
        reconcile()
        return recordsByDriverSessionID.mapValues(\.session)
    }

    /// Resolves a hook only when its surface and current agent generation still
    /// match the live projection.
    ///
    /// Some agents expose different identifiers to the process scanner and hook
    /// protocol. In that case the generation-validated hook parent process is
    /// the authority. A delayed Stop from a replaced process cannot match the
    /// successor's live process tree, so it cannot hide newer pane activity.
    func driverSessionID(
        surfaceID rawSurfaceID: String?,
        agentSessionID: String,
        hookProcessID: Int? = nil
    ) -> String? {
        guard
            let rawSurfaceID,
            let surfaceID = UUID(uuidString: rawSurfaceID)
        else {
            return nil
        }
        reconcile()
        let driverSessionID = ComputerUseSessionScope.driverSessionID(
            surfaceID: surfaceID
        )
        guard let record = recordsByDriverSessionID[driverSessionID],
              record.session.surfaceID == surfaceID
        else {
            return nil
        }
        if record.agentSessionID == agentSessionID {
            return driverSessionID
        }
        guard
            let hookProcessID,
            let processID = pid_t(exactly: hookProcessID),
            let hookProcessIdentity = AgentPIDProcessIdentity(pid: processID),
            ComputerUseCuaState.process(
                hookProcessIdentity,
                belongsToProcessTree: record.session.rootProcessIdentities
            )
        else {
            return nil
        }
        return driverSessionID
    }

    func currentSession(
        matching scannedSession: ComputerUseLiveDriverSession
    ) -> ComputerUseLiveDriverSession? {
        reconcile()
        let driverSessionID = ComputerUseSessionScope.driverSessionID(
            surfaceID: scannedSession.surfaceID
        )
        guard
            let current = recordsByDriverSessionID[driverSessionID]?.session,
            current.workspaceID == scannedSession.workspaceID,
            current.logicalSessionID == scannedSession.logicalSessionID
        else {
            return nil
        }
        return current
    }

    func menuBarRows(
        workspaceTitle: @MainActor (UUID) -> String?
    ) -> [ComputerUseMenuBarRow] {
        reconcile()
        return recordsByDriverSessionID
            .sorted { $0.key < $1.key }
            .map { _, record in
                let session = record.session
                let workspaceName = workspaceTitle(session.workspaceID)
                    ?? String(
                        localized: "computerUse.menu.unknownWorkspace",
                        defaultValue: "Unknown Workspace"
                    )
                return ComputerUseMenuBarRow(
                    id: session.logicalSessionID,
                    title: String(
                        localized: "computerUse.menu.sessionTitle",
                        defaultValue: "\(record.kind.displayName) · \(workspaceName)"
                    ),
                    sessionID: record.agentSessionID,
                    workspaceID: session.workspaceID,
                    surfaceID: session.surfaceID,
                    rootProcessIdentities: session.rootProcessIdentities,
                    targetIdentity: nil,
                    targetAppName: nil,
                    stateWriterIdentity: nil,
                    proxySessionID: nil
                )
            }
    }

    private func reconcile() {
        var currentRecords: [String: Record] = [:]
        for pair in liveEntries() {
            guard
                let session = ComputerUseLiveDriverSession(
                    workspaceID: pair.panelKey.workspaceId,
                    surfaceID: pair.panelKey.panelId,
                    entry: pair.entry
                )
            else {
                continue
            }
            let driverSessionID = ComputerUseSessionScope.driverSessionID(
                surfaceID: pair.panelKey.panelId
            )
            currentRecords[driverSessionID] = Record(
                session: session,
                kind: pair.entry.snapshot.kind,
                agentSessionID: pair.entry.snapshot.sessionId
            )
        }

        for (driverSessionID, retainedRecord) in recordsByDriverSessionID
        where currentRecords[driverSessionID] == nil {
            let rootStillAlive = retainedRecord.session.rootProcessIdentities
                .contains(where: processIdentityIsAlive)
            if rootStillAlive {
                currentRecords[driverSessionID] = retainedRecord
            }
        }
        recordsByDriverSessionID = currentRecords
    }
}
