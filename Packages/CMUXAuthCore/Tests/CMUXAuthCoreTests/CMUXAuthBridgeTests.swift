import CMUXAuthCore
import Foundation
import Testing

@Suite("CMUXAuthBridge")
struct CMUXAuthBridgeTests {
    @Test("Status returns shared auth payload from the cache")
    func statusReturnsSharedAuthPayloadFromCache() throws {
        let store = TestKeyValueStore()
        let user = CMUXAuthUser(
            id: "user_123",
            primaryEmail: "user@example.com",
            displayName: "User Example"
        )
        try CMUXAuthIdentityStore(
            keyValueStore: store,
            key: CMUXAuthBridgeDefaults.cachedUserKey
        ).save(user)
        store.set("team_123", forKey: CMUXAuthBridgeDefaults.selectedTeamIDKey)

        let bridge = CMUXAuthBridge(keyValueStore: store)
        let result = try bridge.handle(
            CMUXAuthBridgeRequest(method: "auth.status", params: [:])
        )

        #expect(result.signedIn)
        #expect(result.authenticated)
        #expect(result.user?.id == user.id)
        #expect(result.user?.email == user.primaryEmail)
        #expect(result.user?.displayName == user.displayName)
        #expect(result.selectedTeamID == "team_123")
        #expect(result.backend == "cmux_auth_core_bridge")
        #expect(result.mode == "bridge")
    }

    @Test("Sign out clears shared auth cache")
    func signOutClearsSharedAuthCache() throws {
        let store = TestKeyValueStore()
        try CMUXAuthIdentityStore(
            keyValueStore: store,
            key: CMUXAuthBridgeDefaults.cachedUserKey
        ).save(CMUXAuthUser(id: "user_123", primaryEmail: nil, displayName: nil))
        store.set("team_123", forKey: CMUXAuthBridgeDefaults.selectedTeamIDKey)

        let bridge = CMUXAuthBridge(keyValueStore: store)
        let result = try bridge.handle(
            CMUXAuthBridgeRequest(method: "auth.sign_out", params: [:])
        )

        #expect(!result.signedIn)
        #expect(result.user == nil)
        #expect(result.selectedTeamID == nil)
        #expect(try CMUXAuthIdentityStore(
            keyValueStore: store,
            key: CMUXAuthBridgeDefaults.cachedUserKey
        ).load() == nil)
    }

    @Test("Unavailable interactive sign in reports backend unavailable")
    func unavailableInteractiveSignInReportsBackendUnavailable() {
        let bridge = CMUXAuthBridge(keyValueStore: TestKeyValueStore())

        do {
            _ = try bridge.handle(
                CMUXAuthBridgeRequest(method: "auth.begin_sign_in", params: [:])
            )
            Issue.record("expected backendUnavailable")
        } catch let error as CMUXAuthBridgeError {
            #expect(error == .backendUnavailable)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
