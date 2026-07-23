import CMUXMobileCore
import Foundation

@MainActor
final class MobileBrowserStreamCoordinator {
    private struct SessionKey: Hashable {
        let connectionID: UUID
        let panelID: UUID
    }

    private var sessions: [SessionKey: MobileBrowserStreamSession] = [:]

    func start(
        connectionID: UUID,
        panel: BrowserPanel,
        viewport: MobileBrowserViewport?
    ) async -> MobileBrowserPanelDescriptor? {
        guard let connection = MobileHostConnectionRegistry.shared.connection(id: connectionID) else {
            return nil
        }
        let key = SessionKey(connectionID: connectionID, panelID: panel.id)
        if let previous = sessions.removeValue(forKey: key) {
            await previous.stop(sendClosed: false)
        }
        if let viewport,
           !panel.applyMobileStreamViewport(
               width: viewport.width,
               height: viewport.height,
               scale: viewport.scale
           ) {
            return nil
        }
        let session = MobileBrowserStreamSession(
            connectionID: connectionID,
            panel: panel,
            connection: connection
        ) { [weak self] sessionID in
            self?.sessionEnded(key: key, sessionID: sessionID)
        }
        sessions[key] = session
        session.start()
        return MobileBrowserWireEncoder().descriptor(panel: panel)
    }

    func hasStream(connectionID: UUID, panelID: UUID) -> Bool {
        sessions[SessionKey(connectionID: connectionID, panelID: panelID)] != nil
    }

    @discardableResult
    func updateViewport(
        connectionID: UUID,
        panel: BrowserPanel,
        viewport: MobileBrowserViewport
    ) -> Bool {
        guard hasStream(connectionID: connectionID, panelID: panel.id) else { return false }
        return panel.applyMobileStreamViewport(
            width: viewport.width,
            height: viewport.height,
            scale: viewport.scale
        )
    }

    @discardableResult
    func stop(connectionID: UUID, panelID: UUID) async -> Bool {
        let key = SessionKey(connectionID: connectionID, panelID: panelID)
        guard let session = sessions.removeValue(forKey: key) else { return false }
        await session.stop(sendClosed: false)
        return true
    }

    @discardableResult
    func acknowledge(connectionID: UUID, panelID: UUID, sequence: UInt64) -> Bool {
        let key = SessionKey(connectionID: connectionID, panelID: panelID)
        guard let session = sessions[key] else { return false }
        session.acknowledge(sequence: sequence)
        return true
    }

    func connectionClosed(_ connectionID: UUID) async {
        let matching = sessions.filter { $0.key.connectionID == connectionID }
        for (key, session) in matching {
            sessions[key] = nil
            await session.stop(sendClosed: false)
        }
    }

    private func sessionEnded(key: SessionKey, sessionID: UUID) {
        guard sessions[key]?.id == sessionID else { return }
        sessions[key] = nil
    }
}
