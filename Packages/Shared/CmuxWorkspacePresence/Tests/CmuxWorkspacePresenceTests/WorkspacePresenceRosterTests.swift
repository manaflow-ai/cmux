import CMUXMobileCore
import CmuxWorkspacePresence
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) @MainActor
struct WorkspacePresenceRosterTests {
    @MainActor private final class Authority { var isCurrent = true }
    private func scope(_ workspace: String, team: String = "team") throws -> WorkspacePresenceScope {
        try #require(WorkspacePresenceScope(kind: .cloud, ownerID: "vm", workspaceID: workspace, teamID: team))
    }

    @Test("each visible Cloud workspace has its own heads while only selection publishes viewing")
    func visibleRowsAndSwitch() async throws {
        let a = try scope("a"), b = try scope("b")
        let transport = PresenceTestTransport()
        let roster = WorkspacePresenceRoster(transport: transport)
        roster.configure(accountID: "self", teamID: "team", accessToken: { "test" }, isCurrent: { true })
        let changes = roster.changes()
        roster.setWorkspaces(observed: [a, b], selected: a, isActive: true)
        let first = try #require(await PresenceTestTransport.next(transport.connections))
        let second = try #require(await PresenceTestTransport.next(transport.connections))
        let connections = [first.scope: first.connection, second.scope: second.connection]
        let connectionA = try #require(connections[a]), connectionB = try #require(connections[b])
        #expect(await PresenceTestTransport.next(connectionA.views) == true)
        #expect(await PresenceTestTransport.next(connectionB.views) == false)

        let ada = WorkspacePresenceParticipant(id: "ada", displayName: "Ada")
        let grace = WorkspacePresenceParticipant(id: "grace", displayName: "Grace")
        await connectionA.deliver(WorkspacePresenceSnapshot(scope: a, participants: [ada, .init(id: "self")]))
        #expect(await PresenceTestTransport.next(changes) == a)
        await connectionB.deliver(WorkspacePresenceSnapshot(scope: b, participants: [grace]))
        #expect(await PresenceTestTransport.next(changes) == b)
        #expect(roster.collaborators(in: a) == [ada])
        #expect(roster.collaborators(in: b) == [grace])

        roster.setWorkspaces(observed: [a, b], selected: b, isActive: true)
        #expect(await PresenceTestTransport.next(connectionA.views) == false)
        #expect(await PresenceTestTransport.next(connectionB.views) == true)
        #expect(roster.collaborators(in: a) == [ada])
        #expect(roster.collaborators(in: b) == [grace])

        roster.setWorkspaces(observed: [a, b], selected: b, isActive: false)
        #expect(await PresenceTestTransport.next(connectionB.views) == false)
        await connectionB.disconnect()
        #expect(await PresenceTestTransport.next(changes) == b)
        #expect(roster.collaborators(in: b).isEmpty)
        #expect(roster.collaborators(in: a) == [ada])
        roster.setWorkspaces(observed: [], selected: nil, isActive: false)
    }

    @Test("account replacement in the same workspace clears heads and reopens with new authority")
    func accountReplacement() async throws {
        let a = try scope("a")
        let transport = PresenceTestTransport()
        let roster = WorkspacePresenceRoster(transport: transport)
        let authority = Authority()
        roster.configure(accountID: "old", teamID: "team", accessToken: { "old-token" }, isCurrent: { authority.isCurrent })
        roster.setWorkspaces(observed: [a], selected: nil, isActive: true)
        let changes = roster.changes()
        let old = try #require(await PresenceTestTransport.next(transport.connections))
        await old.connection.deliver(.init(scope: a, participants: [.init(id: "friend")]))
        #expect(await PresenceTestTransport.next(changes) == a)
        #expect(roster.collaborators(in: a).count == 1)
        authority.isCurrent = false
        #expect(roster.collaborators(in: a).isEmpty)
        roster.configure(accountID: "new", teamID: "team", accessToken: { "new-token" }, isCurrent: { true })
        #expect(roster.collaborators(in: a).isEmpty)
        #expect(await PresenceTestTransport.next(changes) == a)
        let new = try #require(await PresenceTestTransport.next(transport.connections))
        #expect(new.scope == a)
        await new.connection.deliver(.init(scope: a, participants: [.init(id: "new"), .init(id: "other")]))
        #expect(await PresenceTestTransport.next(changes) == a)
        #expect(roster.collaborators(in: a).map(\.id) == ["other"])
        roster.configure(accountID: nil, teamID: nil, accessToken: { nil }, isCurrent: { false })
        #expect(roster.collaborators(in: a).isEmpty)
    }

    @Test("detaching a row closes its passive connection and clears its roster")
    func rowTeardown() async throws {
        let a = try scope("a")
        let transport = PresenceTestTransport()
        let roster = WorkspacePresenceRoster(transport: transport)
        roster.configure(accountID: "self", teamID: "team", accessToken: { "test" }, isCurrent: { true })
        roster.setWorkspaces(observed: [a], selected: nil, isActive: true)
        let connection = try #require(await PresenceTestTransport.next(transport.connections)).connection
        #expect(await PresenceTestTransport.next(connection.views) == false)
        let changes = roster.changes()
        await connection.deliver(.init(scope: a, participants: [.init(id: "friend")]))
        #expect(await PresenceTestTransport.next(changes) == a)
        roster.setWorkspaces(observed: [], selected: nil, isActive: true)
        #expect(roster.collaborators(in: a).isEmpty)
        #expect(await PresenceTestTransport.finishes(connection.views))
    }
}
