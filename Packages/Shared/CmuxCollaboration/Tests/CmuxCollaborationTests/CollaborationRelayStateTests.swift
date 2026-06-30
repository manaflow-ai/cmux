import CmuxCollaboration
import Foundation
import Testing

@Suite
struct CollaborationRelayStateTests {
    @Test
    func relayUnavailableIsExplicitState() async {
        let session = CollaborationSession(peerID: "a", displayName: "A", color: "#111111", sessionID: "s")

        await session.markRelayUnavailable()

        #expect(await session.currentConnectionState() == .relayUnavailable)
    }

    @Test
    func relayDisconnectClearsRemotePresence() async throws {
        let session = CollaborationSession(peerID: "a", displayName: "A", color: "#111111", sessionID: "s")
        let remote = PresenceState(
            peerID: "b",
            displayName: "B",
            color: "#222222",
            activeFile: "note.txt",
            cursor: 1,
            selection: nil,
            sequence: 1
        )

        try await session.applyRemoteFrame(.presence(remote))
        await session.markConnected()
        await session.markDisconnected()

        #expect(await session.currentConnectionState() == .disconnected)
    }
}
