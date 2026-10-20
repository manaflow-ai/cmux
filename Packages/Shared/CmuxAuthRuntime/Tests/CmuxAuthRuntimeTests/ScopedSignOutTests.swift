import CMUXAuthCore
import Testing
@testable import CmuxAuthRuntime

/// Teardown delayed by a Cloud child must never clear a replacement auth session.
@MainActor
@Suite struct ScopedSignOutTests {
    private func signedIn() async throws -> HostBrowserSignInFlowHarness {
        let user = CMUXAuthUser(id: "a", primaryEmail: "a@example.test", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)
        await harness.tokenStore.setTokens(accessToken: "access-a", refreshToken: "refresh-a")
        try await harness.coordinator.signInWithPassword(email: "a@example.test", password: "test")
        return harness
    }

    @Test(arguments: [false, true])
    func aStaleBrowserSignOutPreservesTheReplacementSession(anotherAccount: Bool) async throws {
        let harness = try await signedIn()
        let original = harness.coordinator.authSessionGeneration
        let user = CMUXAuthUser(id: anotherAccount ? "b" : "a", primaryEmail: "new@example.test", displayName: "New")
        await harness.client.setUser(user)
        await harness.tokenStore.setTokens(accessToken: "access-new", refreshToken: "refresh-new")
        try await harness.coordinator.signInWithPassword(email: "new@example.test", password: "test")
        #expect(harness.coordinator.authSessionGeneration != original)
        await harness.flow.signOut(ifGeneration: original)
        #expect(harness.coordinator.currentUser == user)
        #expect(harness.coordinator.isAuthenticated)
        #expect(await harness.tokenStore.getStoredAccessToken() == "access-new")
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-new")
        #expect(await harness.client.revokedCredentials.isEmpty)
    }

    @Test func aStaleCoordinatorSignOutCannotClearANewSession() async throws {
        let harness = try await signedIn()
        let original = harness.coordinator.authSessionGeneration
        await harness.tokenStore.setTokens(accessToken: "access-new", refreshToken: "refresh-new")
        try await harness.coordinator.signInWithPassword(email: "a@example.test", password: "test")
        await harness.coordinator.signOut(ifGeneration: original)
        #expect(harness.coordinator.isAuthenticated)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-new")
        #expect(await harness.client.revokedCredentials.isEmpty)
    }

    @Test func theCapturedCurrentSessionStillSignsOut() async throws {
        let harness = try await signedIn()
        await harness.flow.signOut(ifGeneration: harness.coordinator.authSessionGeneration)
        #expect(!harness.coordinator.isAuthenticated)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
        #expect(await harness.client.revokedCredentials.count == 1)
        #expect(await harness.client.revokedCredentials.first?.access == "access-a")
    }
}
