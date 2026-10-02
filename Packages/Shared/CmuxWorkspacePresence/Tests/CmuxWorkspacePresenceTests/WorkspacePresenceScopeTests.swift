import CMUXMobileCore
import Testing

@Test("cloud scope requires team and excludes Mac tag")
func cloudScopeValidation() throws {
    let scope = try #require(WorkspacePresenceScope(kind: .cloud, ownerID: "vm-1", workspaceID: "ws-1", teamID: "team-1"))
    #expect(scope.teamID == "team-1")
    #expect(WorkspacePresenceScope(kind: .cloud, ownerID: "vm-1", instanceTag: "dev", workspaceID: "ws-1", teamID: "team-1") == nil)
}

@Test("Mac scope is owner and tag specific")
func macScopeValidation() {
    #expect(WorkspacePresenceScope(kind: .mac, ownerID: "not-a-uuid", instanceTag: "default", workspaceID: "not-a-uuid") == nil)
}
