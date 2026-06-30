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

    @Test
    func terminalRelayFramesRoundTrip() throws {
        let workspaceID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let surfaceID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let descriptor = SharedTerminalDescriptor(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            title: "Terminal"
        )
        let frames: [CollaborationRelayFrame] = [
            .terminalOpen(terminalID: "s:terminal:w:t", descriptor: descriptor),
            .terminalOutput(terminalID: "s:terminal:w:t", sequence: 42, data: Data([0x1B, 0x5B, 0x41])),
            .terminalInput(terminalID: "s:terminal:w:t", inputID: "input-1", data: Data("echo ok\r".utf8)),
            .terminalClose(terminalID: "s:terminal:w:t"),
        ]

        let encoded = try JSONEncoder().encode(frames)
        let decoded = try JSONDecoder().decode([CollaborationRelayFrame].self, from: encoded)

        #expect(decoded == frames)
    }
}
