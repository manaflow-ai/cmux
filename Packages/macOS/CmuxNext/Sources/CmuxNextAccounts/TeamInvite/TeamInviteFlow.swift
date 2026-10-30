import Foundation

/// One team invite from start to answer: find the team, ask the person, and
/// only after Allow ask cmux.com to send the email. Every caller that is not
/// the person's own gesture (CLI, MCP, an agent) goes through here, so no
/// invite, which can add a paid seat on accept, leaves without a yes.
@MainActor
public struct TeamInviteFlow {
    private let backend: any TeamInviteBackend
    private let consent: any TeamInviteConsenting

    /// Creates the flow.
    ///
    /// - Parameters:
    ///   - backend: The signed-in cmux.com calls.
    ///   - consent: Who asks the person (the App's panel, a test's script).
    public init(backend: any TeamInviteBackend, consent: any TeamInviteConsenting) {
        self.backend = backend
        self.consent = consent
    }

    /// Runs one invite.
    ///
    /// - Parameters:
    ///   - input: The validated arguments.
    ///   - requester: Who asked, for the confirmation.
    /// - Returns: The receipt, or why nothing was sent.
    public func run(_ input: TeamInviteInput, requester: TeamInviteRequester) async -> Result<TeamInviteReceipt, TeamInviteRefusal> {
        let team: TeamInviteTeam
        do {
            team = try resolveTeam(input.team, among: try await backend.teams())
        } catch let refusal as TeamInviteRefusal {
            return .failure(refusal)
        } catch let error as TeamInviteBackendError {
            return .failure(TeamInviteRefusal(code: error.code, message: error.message))
        } catch {
            return .failure(TeamInviteRefusal(code: "unavailable", message: String(describing: type(of: error))))
        }
        let request = TeamInviteRequest(requester: requester, reason: input.reason, team: team, emails: input.emails, role: input.role)
        switch await consent.ask(request) {
        case .allow: break
        case .deny: return .failure(TeamInviteRefusal(code: "team.denied", message: TeamInviteStrings.denied))
        case .timedOut: return .failure(TeamInviteRefusal(code: "team.timed_out", message: TeamInviteStrings.timedOut))
        }
        let outcome: TeamInviteOutcome
        do {
            outcome = try await backend.invite(teamID: team.id, emails: input.emails, role: input.role)
        } catch let error as TeamInviteBackendError {
            return .failure(TeamInviteRefusal(code: error.code, message: error.message))
        } catch {
            return .failure(TeamInviteRefusal(code: "unavailable", message: String(describing: type(of: error))))
        }
        if outcome.invitations.isEmpty {
            let members = outcome.failed.filter { $0.code == "already_member" }.map(\.email)
            if !members.isEmpty, members.count == outcome.failed.count {
                return .failure(TeamInviteRefusal(code: "team.already_member", message: TeamInviteStrings.alreadyMember(members.joined(separator: ", "))))
            }
            let emails = (outcome.failed.isEmpty ? input.emails : outcome.failed.map(\.email)).joined(separator: ", ")
            return .failure(TeamInviteRefusal(code: "team.invite_failed", message: TeamInviteStrings.failed(emails)))
        }
        let message = TeamInviteStrings.sent(outcome.invitations.map(\.email).joined(separator: ", "), team: team.name)
        return .success(TeamInviteReceipt(team: team, outcome: outcome, message: message))
    }
}

/// The team a run names (an id exactly, else a name in any case), or the one
/// shared team when it names none. A personal team is never the default.
private func resolveTeam(_ named: String?, among teams: [TeamInviteTeam]) throws -> TeamInviteTeam {
    let known = teams.map { "\($0.name) (\($0.id))" }.joined(separator: ", ")
    guard let named else {
        let shared = teams.filter { !$0.personal }
        if shared.count == 1 { return shared[0] }
        if shared.isEmpty { throw TeamInviteRefusal(code: "team.not_found", message: TeamInviteStrings.noTeams) }
        throw TeamInviteRefusal(code: "team.ambiguous", message: TeamInviteStrings.ambiguous(known))
    }
    if let byID = teams.first(where: { $0.id == named }) { return byID }
    let byName = teams.filter { $0.name.compare(named, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    if byName.count == 1 { return byName[0] }
    if byName.isEmpty { throw TeamInviteRefusal(code: "team.not_found", message: TeamInviteStrings.notFound(named, known: known)) }
    throw TeamInviteRefusal(code: "team.ambiguous", message: TeamInviteStrings.ambiguous(byName.map { "\($0.name) (\($0.id))" }.joined(separator: ", ")))
}
