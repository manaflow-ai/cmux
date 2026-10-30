import CmuxNextAccounts
import Testing

/// A team invite from the CLI, MCP or an agent: nothing reaches cmux.com
/// before the person answers Allow, and the run reports the invite's state.
@MainActor
@Suite struct TeamInviteFlowTests {
    static let cmux = TeamInviteTeam(id: "team_cmux", name: "cmux")
    static let personal = TeamInviteTeam(id: "user_1", name: "Lawrence's team", personal: true)
    static let other = TeamInviteTeam(id: "team_other", name: "Manaflow")
    static let agent = TeamInviteRequester(kind: .agentChat, name: "a847", tabID: "tab_1")

    /// Records every call so a test can assert what was (not) sent and in which order.
    actor Backend: TeamInviteBackend {
        var teamList: [TeamInviteTeam]
        var answer: TeamInviteOutcome?
        private(set) var invites: [(teamID: String, emails: [String], role: TeamInviteRole)] = []

        init(teams: [TeamInviteTeam], answer: TeamInviteOutcome? = nil) {
            teamList = teams
            self.answer = answer
        }

        func teams() async throws -> [TeamInviteTeam] { teamList }

        func invite(teamID: String, emails: [String], role: TeamInviteRole) async throws -> TeamInviteOutcome {
            invites.append((teamID, emails, role))
            return answer ?? TeamInviteOutcome(invitations: emails.map {
                .init(id: "inv_\($0)", email: $0, role: role.rawValue, expiresAt: "2026-11-05T00:00:00.000Z")
            })
        }
    }

    @MainActor final class Consent: TeamInviteConsenting {
        let answer: TeamInviteAnswer
        private(set) var asked: [TeamInviteRequest] = []
        init(_ answer: TeamInviteAnswer) { self.answer = answer }
        func ask(_ request: TeamInviteRequest) async -> TeamInviteAnswer {
            asked.append(request)
            return answer
        }
    }

    private func run(_ input: TeamInviteInput, backend: Backend, consent: Consent)
        async -> Result<TeamInviteReceipt, TeamInviteRefusal> {
        await TeamInviteFlow(backend: backend, consent: consent).run(input, requester: Self.agent)
    }

    @Test func denyNeverSendsTheInvite() async throws {
        let backend = Backend(teams: [Self.personal, Self.cmux])
        let consent = Consent(.deny)
        let result = await run(try TeamInviteInput(email: "leo@cmux.com", reason: "user asked"), backend: backend, consent: consent)
        #expect(consent.asked.count == 1)
        #expect(await backend.invites.isEmpty)
        #expect(result.refusalCode == "team.denied")
    }

    @Test func noAnswerNeverSendsTheInvite() async throws {
        let backend = Backend(teams: [Self.cmux])
        let consent = Consent(.timedOut)
        let result = await run(try TeamInviteInput(email: "leo@cmux.com"), backend: backend, consent: consent)
        #expect(await backend.invites.isEmpty)
        #expect(result.refusalCode == "team.timed_out")
    }

    @Test func allowSendsOnceAndReportsThePendingInvite() async throws {
        let backend = Backend(teams: [Self.personal, Self.cmux])
        let consent = Consent(.allow)
        let result = await run(try TeamInviteInput(email: "Leo@cmux.com", team: "cmux", reason: "user asked"),
                               backend: backend, consent: consent)
        let request = try #require(consent.asked.first)
        #expect(request.team == Self.cmux)
        #expect(request.emails == ["leo@cmux.com"])
        #expect(request.role == .member)
        #expect(request.reason == "user asked")
        #expect(request.requester == Self.agent)
        let sent = await backend.invites
        #expect(sent.count == 1)
        #expect(sent.first?.teamID == "team_cmux")
        #expect(sent.first?.emails == ["leo@cmux.com"])
        let receipt = try result.get()
        #expect(receipt.team == Self.cmux)
        #expect(receipt.outcome.invitations.map(\.email) == ["leo@cmux.com"])
        #expect(receipt.outcome.invitations.first?.id == "inv_leo@cmux.com")
    }

    @Test func theOnlySharedTeamIsTheDefault() async throws {
        let backend = Backend(teams: [Self.personal, Self.cmux])
        let consent = Consent(.allow)
        _ = await run(try TeamInviteInput(email: "leo@cmux.com"), backend: backend, consent: consent)
        #expect(await backend.invites.first?.teamID == "team_cmux")
    }

    @Test(arguments: ["CMUX", "team_cmux"])
    func aTeamIsNamedByNameOrID(_ name: String) async throws {
        let backend = Backend(teams: [Self.other, Self.cmux])
        let consent = Consent(.allow)
        _ = await run(try TeamInviteInput(email: "leo@cmux.com", team: name), backend: backend, consent: consent)
        #expect(await backend.invites.first?.teamID == "team_cmux")
    }

    @Test func severalTeamsAndNoneNamedAsksNothing() async throws {
        let backend = Backend(teams: [Self.other, Self.cmux])
        let consent = Consent(.allow)
        let result = await run(try TeamInviteInput(email: "leo@cmux.com"), backend: backend, consent: consent)
        #expect(consent.asked.isEmpty)
        #expect(await backend.invites.isEmpty)
        #expect(result.refusalCode == "team.ambiguous")
    }

    @Test func anUnknownTeamAsksNothing() async throws {
        let backend = Backend(teams: [Self.cmux])
        let consent = Consent(.allow)
        let result = await run(try TeamInviteInput(email: "leo@cmux.com", team: "nope"), backend: backend, consent: consent)
        #expect(consent.asked.isEmpty)
        #expect(result.refusalCode == "team.not_found")
    }

    @Test func anAlreadyMemberIsReportedNotSilentlyOK() async throws {
        let backend = Backend(teams: [Self.cmux],
                              answer: TeamInviteOutcome(invitations: [], failed: [.init(email: "leo@cmux.com", code: "already_member")]))
        let consent = Consent(.allow)
        let result = await run(try TeamInviteInput(email: "leo@cmux.com"), backend: backend, consent: consent)
        #expect(result.refusalCode == "team.already_member")
    }

    @Test func addressesAreCheckedBeforeAnything() throws {
        let input = try TeamInviteInput(email: "Leo@cmux.com, leo@cmux.com aziz@cmux.com", role: "ADMIN")
        #expect(input.emails == ["leo@cmux.com", "aziz@cmux.com"])
        #expect(input.role == .admin)
        #expect(throws: TeamInviteRefusal.self) { try TeamInviteInput(email: nil) }
        #expect(throws: TeamInviteRefusal.self) { try TeamInviteInput(email: "leo") }
        #expect(throws: TeamInviteRefusal.self) { try TeamInviteInput(email: "Leo <leo@cmux.com>") }
        #expect(throws: TeamInviteRefusal.self) { try TeamInviteInput(email: "leo@cmux.com", role: "owner") }
    }
}

private extension Result where Failure == TeamInviteRefusal {
    var refusalCode: String? {
        if case .failure(let refusal) = self { return refusal.code }
        return nil
    }
}
