import CMUXMobileCore
import CmuxWorkspacePresence
import Foundation
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

/// Verifies activity encoding and compatibility with snapshots from older workers.
@Test("participant activity is encoded on the wire and defaults for older snapshots")
func participantActivityCoding() throws {
    let inactive = WorkspacePresenceParticipant(id: "u", displayName: "Ada", isActive: false)
    let encoded = try JSONEncoder().encode(inactive)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["active"] as? Bool == false)
    #expect(try JSONDecoder().decode(WorkspacePresenceParticipant.self, from: encoded) == inactive)

    let legacy = Data(#"{"id":"u","displayName":"Ada"}"#.utf8)
    #expect(try JSONDecoder().decode(WorkspacePresenceParticipant.self, from: legacy).isActive)
}
