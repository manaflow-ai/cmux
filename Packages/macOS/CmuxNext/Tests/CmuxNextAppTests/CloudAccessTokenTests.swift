import CmuxInstallAuthCore
@testable import CmuxNextCloud
import CmuxNextHomeEngine
import Foundation
import Testing

/// The mint behind `auth.token` (`cmux auth token`, cmux-platform#111), against the test
/// owner that verifies the real Mac signer (MacTeamAuthOwner).
@Suite struct CloudAccessTokenTests {
    private let team = "team_" + String(repeating: "a", count: 20)
    private let personalTeam = "team_" + String(repeating: "c", count: 20)

    private func identity(_ owner: MacTeamAuthOwner, root: URL) -> MacInstallIdentity {
        MacInstallIdentity(store: .files(directory: root), transport: owner, deviceName: "Test Mac", clientVersion: "2.4.0")
    }

    private func scratch() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @Test func noTeamMintsAFreshTokenForTheInstallsOwnTeam() async throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = MacTeamAuthOwner(), identity = identity(owner, root: root)
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })
        let token = try await identity.accessToken(team: nil)
        #expect(token.team == personalTeam)
        #expect(token.user == "user_1")
        #expect(MacInstallIdentity.team(ofToken: token.accessToken) == personalTeam)
        // A scoped mint, not the cached personal token: every call has a full lifetime.
        #expect(await owner.requestedTeams == [personalTeam])
        #expect(await owner.grants.allSatisfy { !$0.contains("execute") })
    }

    @Test func anAskedTeamIsTheTokensTeam() async throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = MacTeamAuthOwner(), identity = identity(owner, root: root)
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })
        let token = try await identity.accessToken(team: team)
        #expect(token.team == team)
        #expect(MacInstallIdentity.team(ofToken: token.accessToken) == team)
    }

    @Test func signedOutBadAndDeniedTeamsAreTheirOwnFailures() async throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = MacTeamAuthOwner(), identity = identity(owner, root: root)
        await #expect(throws: CloudAccessToken.Failure.signedOut) { try await identity.accessToken(team: nil) }
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })
        await #expect(throws: CloudAccessToken.Failure.invalidTeam) { try await identity.accessToken(team: "personal") }
        #expect(await owner.requestedTeams.isEmpty)
        await owner.deny(team)
        await #expect(throws: CloudAccessToken.Failure.refused("auth.forbidden")) { try await identity.accessToken(team: team) }
    }

    @Test func installFailuresMapToTheCodesTheCLIActsOn() {
        #expect(CloudAccessToken.failure(MacInstallIdentity.Failure.signedOut) == .signedOut)
        #expect(CloudAccessToken.failure(InstallAuthError.noSession) == .signedOut)
        #expect(CloudAccessToken.failure(InstallAuthError.transport) == .unreachable)
        #expect(CloudAccessToken.failure(InstallAuthError.clientTooOld(minimumVersion: "3.0")) == .clientTooOld(minimumVersion: "3.0"))
        #expect(CloudAccessToken.failure(InstallAuthError.unexpectedChallenge) == .badReply)
        // A server or rate-limit status is the service's trouble, never "not a member".
        #expect(CloudAccessToken.failure(InstallAuthError.refused("http_503")) == .unreachable)
        #expect(CloudAccessToken.failure(InstallAuthError.refused("http_429")) == .unreachable)
        #expect(CloudAccessToken.failure(InstallAuthError.refused("auth.rate_limited")) == .unreachable)
        #expect(CloudAccessToken.failure(InstallAuthError.refused("http_403")) == .refused("http_403"))
        #expect(CloudAccessToken.failure(InstallAuthError.refused("auth.forbidden")) == .refused("auth.forbidden"))
        #expect(CloudAccessToken.Failure.signedOut.code == "not_signed_in")
        #expect(CloudAccessToken.Failure.noTeam.code == "no_team")
        #expect(CloudAccessToken.Failure.invalidTeam.code == "invalid_params")
        #expect(CloudAccessToken.Failure.refused("auth.forbidden").code == "forbidden")
        #expect(CloudAccessToken.Failure.refused("auth.forbidden").detail == "auth.forbidden")
        #expect(CloudAccessToken.Failure.clientTooOld(minimumVersion: "3.0").detail == "3.0")
        #expect(CloudAccessToken.Failure.unreachable.code == "unavailable")
    }

    @Test func claimsAreReadFromTheToken() throws {
        let claims = try JSONSerialization.data(withJSONObject: ["sub": "user_1", "team": team, "exp": 1_900_000_600], options: [.sortedKeys])
        let token = CloudAccessToken(token: "eyJhbGciOiJFUzI1NiJ9.\(claims.base64URLEncoded).c2ln", team: team)
        #expect(token.user == "user_1")
        #expect(token.expiresAt == Date(timeIntervalSince1970: 1_900_000_600))
        let opaque = CloudAccessToken(token: "not-a-jwt", team: team)
        #expect(opaque.user == nil)
        #expect(opaque.expiresAt == nil)
        #expect(CloudAccessToken.isTeam(team))
        #expect(!CloudAccessToken.isTeam("team_" + String(repeating: "A", count: 20)))
        #expect(!CloudAccessToken.isTeam("personal"))
    }

    @Test func theDefaultIsTheActiveTeamAndAManagedDeviceMintsOnlyForItsTeam() throws {
        let project = "proj_1", stackTeam = "6F1C2D9E-0000-4000-8000-000000000001", other = "6f1c2d9e-0000-4000-8000-000000000002"
        let backend = CloudAccessToken.backendTeamID(stackProjectID: project, stackTeamID: stackTeam)
        // The same id the Worker and Home use for that team.
        #expect(backend == CloudIdentity.workerTeamID(stackProjectID: project, stackTeamID: stackTeam))
        #expect(CloudAccessToken.isTeam(backend))
        // Unmanaged: the asked team, else the active team, else the install's own (personal) team.
        #expect(try CloudAccessToken.team(requested: team, activeStackTeam: stackTeam, managedStackTeam: nil, stackProjectID: project) == team)
        #expect(try CloudAccessToken.team(requested: nil, activeStackTeam: stackTeam, managedStackTeam: nil, stackProjectID: project) == backend)
        #expect(try CloudAccessToken.team(requested: nil, activeStackTeam: nil, managedStackTeam: nil, stackProjectID: project) == nil)
        // Managed (RestrictToManagedTeam): only its team, only while it is the active one, never personal.
        #expect(try CloudAccessToken.team(requested: nil, activeStackTeam: stackTeam, managedStackTeam: stackTeam, stackProjectID: project) == backend)
        #expect(try CloudAccessToken.team(requested: backend, activeStackTeam: stackTeam, managedStackTeam: stackTeam, stackProjectID: project) == backend)
        #expect(throws: CloudAccessToken.Failure.managed) {
            try CloudAccessToken.team(requested: team, activeStackTeam: stackTeam, managedStackTeam: stackTeam, stackProjectID: project)
        }
        #expect(throws: CloudAccessToken.Failure.managed) {
            try CloudAccessToken.team(requested: nil, activeStackTeam: nil, managedStackTeam: stackTeam, stackProjectID: project)
        }
        #expect(throws: CloudAccessToken.Failure.managed) {
            try CloudAccessToken.team(requested: nil, activeStackTeam: other, managedStackTeam: stackTeam, stackProjectID: project)
        }
        #expect(CloudAccessToken.Failure.managed.code == "managed")
    }
}
