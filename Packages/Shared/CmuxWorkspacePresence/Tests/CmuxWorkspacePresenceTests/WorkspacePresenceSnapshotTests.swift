import CMUXMobileCore
import CmuxWorkspacePresence
import Testing

@Test("snapshot rejects the wrong workspace and duplicate identities")
func snapshotValidation() throws {
    let scope = try #require(WorkspacePresenceScope(kind: .cloud, ownerID: "vm-1", workspaceID: "ws-1", teamID: "team-1"))
    let duplicate = WorkspacePresenceSnapshot(scope: scope, participants: [WorkspacePresenceParticipant(id: "u"), WorkspacePresenceParticipant(id: "u")])
    #expect(!duplicate.isValid(for: scope))
    let other = try #require(WorkspacePresenceScope(kind: .cloud, ownerID: "vm-1", workspaceID: "ws-2", teamID: "team-1"))
    let valid = WorkspacePresenceSnapshot(scope: scope, participants: [WorkspacePresenceParticipant(id: "u")])
    #expect(!valid.isValid(for: other))
}
