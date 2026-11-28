import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// An ``AuthClient`` that records the address each magic-link send was asked
/// to deliver to.
actor RecordingMagicLinkAuthClient: AuthClient {
    private(set) var sentEmails: [String] = []

    func accessToken() async -> String? { nil }
    func refreshToken() async -> String? { nil }
    func forceRefreshAccessToken() async -> String? { nil }
    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? { nil }
    func listTeams() async throws -> [CMUXAuthTeam] { [] }

    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String {
        sentEmails.append(email)
        return "nonce"
    }

    func signInWithMagicLink(code: String) async throws {}
    func signInWithCredential(email: String, password: String) async throws {}
    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {}
    func storedAccessToken() async -> String? { nil }
    func clearLocalSession() async {}
    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {}
    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}
    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? { accessToken }
}

@MainActor
@Suite struct AuthCoordinatorEmailCodeAddressTests {
    private func makeCoordinator(client: any AuthClient) -> AuthCoordinator {
        let store = FakeKeyValueStore()
        return AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain(),
            timeouts: AuthTimeouts(interactiveFlow: .seconds(5), network: .seconds(2)),
            clock: ManualTestClock()
        )
    }

    /// iOS autofill and QuickType can leave a space or newline around the
    /// address. The sign-in service rejects that as a malformed email, which
    /// the app showed as "Please enter a valid email address" for an address
    /// that looked correct on screen.
    @Test(arguments: [" person@example.com", "person@example.com ", "\tperson@example.com\n"])
    func sendCodeDropsSurroundingWhitespace(typed: String) async throws {
        let client = RecordingMagicLinkAuthClient()
        let coordinator = makeCoordinator(client: client)

        try await coordinator.sendCode(to: typed)

        #expect(await client.sentEmails == ["person@example.com"])
    }
}
