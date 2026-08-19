import CMUXMobileCore
import Foundation

@MainActor
final class MobileSimulatorStreamCoordinator {
    enum StartResult {
        case started(MobileSimulatorPanelDescriptor)
        case locked(MobileSimulatorPanelDescriptor)
        case unavailable
    }

    private struct SessionKey: Hashable {
        let connectionID: UUID
        let panelID: UUID
    }

    private var sessions: [SessionKey: MobileSimulatorStreamSession] = [:]
    private var ownersByPanelID: [UUID: UUID] = [:]
    private var workspaceIDsByPanelID: [UUID: UUID] = [:]
    private var lastFramesByPanelID: [UUID: MobileSimulatorFrameEvent] = [:]
    private let wireEncoder = MobileSimulatorWireEncoder()

    func start(connectionID: UUID, panel: SimulatorPanel, workspaceID: UUID) async -> StartResult {
        recordStream(
            panel.id,
            .startRequested,
            ownership: currentOwnership(panelID: panel.id, connectionID: connectionID)
        )
        guard let connection = MobileHostConnectionRegistry.shared.connection(id: connectionID) else {
            recordStream(panel.id, .startFailed, ownership: .unknown)
            return .unavailable
        }
        workspaceIDsByPanelID[panel.id] = workspaceID
        if let owner = ownersByPanelID[panel.id], owner != connectionID {
            guard let descriptor = descriptor(panel: panel, currentConnectionID: connectionID) else {
                recordStream(panel.id, .startFailed, ownership: .otherConnection)
                return .unavailable
            }
            recordStream(panel.id, .locked, ownership: .otherConnection)
            return .locked(descriptor)
        }

        let key = SessionKey(connectionID: connectionID, panelID: panel.id)
        if let previous = sessions.removeValue(forKey: key) {
            await previous.stop(sendClosed: false)
        }

        let previousOwnership = currentOwnership(panelID: panel.id, connectionID: connectionID)
        ownersByPanelID[panel.id] = connectionID
        MobileSimulatorDiagnostics.recordOwnership(
            panelID: panel.id,
            ownership: .currentConnection,
            previousOwnership: previousOwnership
        )
        let session = MobileSimulatorStreamSession(
            connectionID: connectionID,
            panel: panel,
            connection: connection,
            cachedFrame: lastFramesByPanelID[panel.id],
            descriptorProvider: { [weak self, weak panel] currentConnectionID in
                guard let self, let panel else { return nil }
                return self.descriptor(panel: panel, currentConnectionID: currentConnectionID)
            },
            onFrame: { [weak self] panelID, frame in
                self?.lastFramesByPanelID[panelID] = frame
            },
            onEnded: { [weak self] sessionID in
                self?.sessionEnded(key: key, sessionID: sessionID)
            }
        )
        sessions[key] = session
        session.start()
        pruneCachesForClosedPanels()
        guard let descriptor = descriptor(panel: panel, currentConnectionID: connectionID) else {
            recordStream(panel.id, .startFailed, ownership: .currentConnection)
            return .unavailable
        }
        recordStream(panel.id, .started, ownership: .currentConnection)
        return .started(descriptor)
    }

    func descriptor(
        panel: SimulatorPanel,
        currentConnectionID: UUID? = nil
    ) -> MobileSimulatorPanelDescriptor? {
        guard let workspaceID = workspaceIDsByPanelID[panel.id]
            ?? AppDelegate.shared?.locateSurface(surfaceId: panel.id)?.workspaceId else {
            return nil
        }
        return wireEncoder.descriptor(
            panel: panel,
            workspaceID: workspaceID,
            ownerConnectionID: ownersByPanelID[panel.id],
            currentConnectionID: currentConnectionID
        )
    }

    func hasControl(connectionID: UUID, panelID: UUID) -> Bool {
        ownersByPanelID[panelID] == connectionID
    }

    @discardableResult
    func stop(connectionID: UUID, panelID: UUID) async -> Bool {
        let key = SessionKey(connectionID: connectionID, panelID: panelID)
        guard let session = sessions.removeValue(forKey: key) else { return false }
        recordStream(
            panelID,
            .stopRequested,
            ownership: currentOwnership(panelID: panelID, connectionID: connectionID),
            activeSessions: sessions.count + 1
        )
        await session.stop(sendClosed: false)
        releaseOwnership(key, recording: .stopped)
        pruneCachesForClosedPanels()
        return true
    }

    func connectionClosed(_ connectionID: UUID) async {
        let matching = sessions.filter { $0.key.connectionID == connectionID }
        for (key, session) in matching {
            sessions[key] = nil
            await session.stop(sendClosed: false)
            releaseOwnership(key, recording: .closed)
        }
        pruneCachesForClosedPanels()
    }

    /// Replays frames only through sessions owned by the connection whose
    /// bounded event queue shed them.
    func requestFrameReplay(connectionID: UUID, panelIDStrings: Set<String>) {
        for panelIDString in panelIDStrings {
            guard let panelID = UUID(uuidString: panelIDString),
                  let session = sessions[SessionKey(connectionID: connectionID, panelID: panelID)] else {
                continue
            }
            session.requestFrameReplay()
        }
    }

    private func sessionEnded(key: SessionKey, sessionID: UUID) {
        guard sessions[key]?.id == sessionID else { return }
        sessions[key] = nil
        releaseOwnership(key, recording: .closed)
        pruneCachesForClosedPanels()
    }

    /// Releases `key`'s panel ownership when its connection still holds it,
    /// then records the stream lifecycle transition for the removed session.
    private func releaseOwnership(_ key: SessionKey, recording state: DiagnosticSimulatorStreamLifecycle) {
        if ownersByPanelID[key.panelID] == key.connectionID {
            ownersByPanelID[key.panelID] = nil
            MobileSimulatorDiagnostics.recordOwnership(
                panelID: key.panelID,
                ownership: .unowned,
                previousOwnership: .currentConnection
            )
        }
        recordStream(key.panelID, state, ownership: .unowned)
    }

    private func recordStream(
        _ panelID: UUID,
        _ state: DiagnosticSimulatorStreamLifecycle,
        ownership: DiagnosticSimulatorOwnershipState,
        activeSessions: Int? = nil
    ) {
        MobileSimulatorDiagnostics.recordStream(
            panelID: panelID,
            state: state,
            ownership: ownership,
            activeSessions: activeSessions ?? sessions.count
        )
    }

    private func currentOwnership(panelID: UUID, connectionID: UUID) -> DiagnosticSimulatorOwnershipState {
        MobileSimulatorDiagnostics.ownershipState(
            ownerConnectionID: ownersByPanelID[panelID],
            currentConnectionID: connectionID
        )
    }

    /// `lastFramesByPanelID` intentionally survives session stop so a
    /// reconnecting phone gets an instant warm frame, but a panel the user
    /// closed never streams again, so its cached full-size frame (and
    /// workspace mapping) would otherwise live for the app's lifetime. There
    /// is no panel-close hook into this coordinator; every mutation entry
    /// point sweeps instead, and the sweep resolves panels through the same
    /// surface locator the input RPCs use.
    private func pruneCachesForClosedPanels() {
        // A panel with a live session is never pruned: its session holds the
        // panel strongly, so a transient locator miss (workspace mid-move)
        // must not drop the mapping the session's descriptors rely on.
        let activePanelIDs = Set(sessions.keys.map(\.panelID))
        let cachedPanelIDs = Set(workspaceIDsByPanelID.keys).union(lastFramesByPanelID.keys)
        for panelID in cachedPanelIDs
        where !activePanelIDs.contains(panelID)
            && AppDelegate.shared?.locateSurface(surfaceId: panelID) == nil {
            workspaceIDsByPanelID.removeValue(forKey: panelID)
            lastFramesByPanelID.removeValue(forKey: panelID)
        }
    }
}
