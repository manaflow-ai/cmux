import Foundation
import Testing
@testable import CmuxInstallAuthCore

@Suite struct InstallTeamTokenTests {
    private let team = "team_" + String(repeating: "a", count: 20)
    private let other = "team_" + String(repeating: "b", count: 20)

    private func scoped(_ owner: FakeOwner, _ signer: SoftwareSigner, record: InstallRecord?, team: String,
                        profile: InstallProfile = .mac, environment: String? = nil) -> InstallAuthClient {
        InstallAuthClient(transport: owner, signer: signer, sessionToken: nil,
                          stackUser: "stack_1", deviceName: "Laptop", clientVersion: "2.4.0", record: record,
                          profile: profile, team: team, expectedEnvironment: environment)
    }

    private func claim(_ token: String, _ name: String) throws -> String? {
        let payload = try #require(Data(base64URLEncoded: String(token.split(separator: ".")[1])))
        return (try JSONSerialization.jsonObject(with: payload) as? [String: Any])?[name] as? String
    }

    @Test func sharedTeamsUseTheSameInstallWithSeparateImmutableTokenCaches() async throws {
        let owner = FakeOwner(), signer = SoftwareSigner(), personal = makeClient(owner, signer, profile: .mac)
        let personalToken = try await personal.installToken(), record = await personal.currentRecord
        let first = scoped(owner, signer, record: record, team: team), second = scoped(owner, signer, record: record, team: other)
        let firstToken = try await first.installToken(), secondToken = try await second.installToken()
        #expect(try claim(firstToken, "team") == team)
        #expect(try claim(secondToken, "team") == other)
        #expect(try await personal.installToken() == personalToken)
        #expect(try await first.installToken() == firstToken)
        #expect(try await second.installToken() == secondToken)
        #expect(await owner.requestedTeams == [team, other])
        #expect(await owner.mints == 3)
        #expect(await owner.installCount == 1)
        #expect(await signer.rotations == 0)
    }

    @Test func aDeniedTeamKeepsTheInstallKeyAndRecordWithoutFallingBackToPersonal() async throws {
        let owner = FakeOwner(), signer = SoftwareSigner(), personal = makeClient(owner, signer)
        _ = try await personal.installToken()
        let record = await personal.currentRecord
        await owner.denyTeam(team)
        let client = scoped(owner, signer, record: record, team: team)
        await #expect(throws: InstallAuthError.refused("auth.forbidden")) { try await client.installToken() }
        #expect(await client.currentRecord == record)
        #expect(await signer.rotations == 0)
        #expect(await owner.installCount == 1)
        #expect(await owner.mints == 1)
    }

    @Test func aChallengeForAnotherTeamIsNeverSigned() async throws {
        let owner = FakeOwner(), signer = SoftwareSigner(), personal = makeClient(owner, signer)
        _ = try await personal.installToken()
        let signed = await signer.signatures
        await owner.setPrefixOverride("cmux-auth-team-v1\nstaging\ninst_1\n\(other)\n")
        let client = scoped(owner, signer, record: await personal.currentRecord, team: team)
        await #expect(throws: InstallAuthError.unexpectedChallenge) { try await client.installToken() }
        #expect(await signer.signatures == signed)
    }

    @Test(arguments: [false, true])
    func bothTheReplyAndTokenMustNameTheRequestedTeam(token: Bool) async throws {
        let owner = FakeOwner(), signer = SoftwareSigner(), personal = makeClient(owner, signer)
        _ = try await personal.installToken()
        if token { await owner.setTokenTeamOverride(other) } else { await owner.setReplyTeamOverride(other) }
        let client = scoped(owner, signer, record: await personal.currentRecord, team: team)
        await #expect(throws: InstallAuthError.unexpectedChallenge) { try await client.installToken() }
        #expect(await signer.rotations == 0)
    }

    @Test(arguments: [InstallProfile.mac, .ios])
    func concurrentCallsShareOnlyTheirOwnScopesMint(profile: InstallProfile) async throws {
        let owner = FakeOwner(), signer = SoftwareSigner(), personal = makeClient(owner, signer, profile: profile)
        _ = try await personal.installToken()
        let client = scoped(owner, signer, record: await personal.currentRecord, team: team, profile: profile)
        async let first = client.installToken()
        async let second = client.installToken()
        let values = try await [first, second]
        #expect(values[0] == values[1])
        #expect(try claim(values[0], "team") == team)
        #expect(await owner.mints == 2)
    }

    @Test(arguments: ["team_bad", "team_" + String(repeating: "A", count: 20), "team_" + String(repeating: "a", count: 20) + "\n"])
    func malformedTeamsAreRefusedBeforeAnySignature(team: String) async throws {
        let owner = FakeOwner(), signer = SoftwareSigner()
        let client = scoped(owner, signer, record: InstallRecord(user: "user_1", install: "inst_1"), team: team)
        await #expect(throws: InstallAuthError.unexpectedChallenge) { try await client.installToken() }
        #expect(await signer.signatures == 0)
        #expect(await owner.requestedTeams.isEmpty)
    }

    @Test func anAlreadyLearnedEnvironmentIsCheckedBeforeSigning() async throws {
        let owner = FakeOwner(), signer = SoftwareSigner(), personal = makeClient(owner, signer)
        _ = try await personal.installToken()
        let signed = await signer.signatures
        await owner.setEnvironment("production")
        let client = scoped(owner, signer, record: await personal.currentRecord, team: team, environment: "staging")
        await #expect(throws: InstallAuthError.unexpectedChallenge) { try await client.installToken() }
        #expect(await signer.signatures == signed)
    }

    @Test(arguments: ["sub", "inst", "grant", "aud", "agt", "vm", "tvm"])
    func aScopedTokenCannotChangeItsIdentityOrActor(claim: String) async throws {
        let owner = FakeOwner(), signer = SoftwareSigner(), personal = makeClient(owner, signer)
        _ = try await personal.installToken()
        await owner.setClaim(claim, "another-principal")
        let client = scoped(owner, signer, record: await personal.currentRecord, team: team)
        await #expect(throws: InstallAuthError.unexpectedChallenge) { try await client.installToken() }
        #expect(await signer.rotations == 0)
    }
}
