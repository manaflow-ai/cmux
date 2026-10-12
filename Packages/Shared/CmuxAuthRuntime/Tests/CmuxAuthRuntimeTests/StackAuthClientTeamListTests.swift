import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Stack's `getUser(or: .returnNull)` answers nil for any failure, including a
/// dropped `/users/me` request. A team list must not turn that into "no teams":
/// the coordinator would record an empty membership as loaded and never retry,
/// so a paid account looks teamless until it signs in again (#20051).
@Suite struct StackAuthClientTeamListTests {
    @Test func listTeamsThrowsWhenStackHasNoSession() async {
        let client = StackAuthClient(
            config: AuthConfig(environment: .production),
            tokenStore: .memory,
            baseURL: "http://127.0.0.1:1",
            noAutomaticPrefetch: true
        )

        await #expect(throws: (any Error).self) {
            _ = try await client.listTeams()
        }
    }

    @Test func listTeamsThrowsWhenTokenRefreshFails() async {
        // The stored access token is not a fresh JWT, so Stack refreshes it
        // against a closed local port: the refresh fails like a dropped
        // connection and no usable token resolves.
        let client = StackAuthClient(
            config: AuthConfig(environment: .production),
            tokenStore: .explicit(accessToken: "access", refreshToken: "refresh"),
            baseURL: "http://127.0.0.1:1",
            noAutomaticPrefetch: true
        )

        await #expect(throws: (any Error).self) {
            _ = try await client.listTeams()
        }
    }
}
