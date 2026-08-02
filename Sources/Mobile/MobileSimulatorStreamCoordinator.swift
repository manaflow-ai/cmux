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
        guard let connection = MobileHostConnectionRegistry.shared.connection(id: connectionID) else {
            return .unavailable
        }
        workspaceIDsByPanelID[panel.id] = workspaceID
        if let owner = ownersByPanelID[panel.id], owner != connectionID {
            guard let descriptor = descriptor(panel: panel, currentConnectionID: connectionID) else {
                return .unavailable
            }
            return .locked(descriptor)
        }

        let key = SessionKey(connectionID: connectionID, panelID: panel.id)
        if let previous = sessions.removeValue(forKey: key) {
            await previous.stop(sendClosed: false)
        }

        ownersByPanelID[panel.id] = connectionID
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
        guard let descriptor = descriptor(panel: panel, currentConnectionID: connectionID) else {
            return .unavailable
        }
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
        await session.stop(sendClosed: false)
        if ownersByPanelID[panelID] == connectionID {
            ownersByPanelID[panelID] = nil
        }
        return true
    }

    func connectionClosed(_ connectionID: UUID) async {
        let matching = sessions.filter { $0.key.connectionID == connectionID }
        for (key, session) in matching {
            sessions[key] = nil
            await session.stop(sendClosed: false)
            if ownersByPanelID[key.panelID] == connectionID {
                ownersByPanelID[key.panelID] = nil
            }
        }
    }

    private func sessionEnded(key: SessionKey, sessionID: UUID) {
        guard sessions[key]?.id == sessionID else { return }
        sessions[key] = nil
        if ownersByPanelID[key.panelID] == key.connectionID {
            ownersByPanelID[key.panelID] = nil
        }
    }
}
