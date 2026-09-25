import CMUXMobileCore
import CmuxWorkspacePresence
import Testing

@Suite(.timeLimit(.minutes(1))) @MainActor
struct WorkspacePresenceSessionTests {
    @Test("a disconnected viewer disappears from the same stream used by sidebar rows")
    func disconnectPublishesEmptyRoster() async throws {
        let scope = try #require(WorkspacePresenceScope(kind: .cloud, ownerID: "vm", workspaceID: "one", teamID: "team"))
        let transport = PresenceTestTransport()
        let session = WorkspacePresenceSession(transport: transport)
        let snapshots = session.snapshots()
        let run = Task { await session.run(scope: scope, accessToken: { "test" }, isCurrent: { true }) }
        defer { run.cancel(); session.stop() }
        let opened = try #require(await PresenceTestTransport.next(transport.connections))
        let ada = WorkspacePresenceParticipant(id: "ada", displayName: "Ada")
        await opened.connection.deliver(WorkspacePresenceSnapshot(scope: scope, participants: [ada]))
        #expect(await PresenceTestTransport.next(snapshots, matching: { !$0.isEmpty }) == [ada])
        await opened.connection.disconnect()
        #expect(await PresenceTestTransport.next(snapshots) == [])
    }
}
