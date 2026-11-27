public import AppKit
public import CmuxHomeCore
public import CmuxNextActions
public import CmuxNextCloud
import CmuxNextHome
import CmuxNextHomeModel

/// `home.inviteToTeam`'s one run: the active team's email invite, always through
/// ``HomeTeamInviteSheet``.
///
/// One path for the Home compose and team menu, New Message's To: row, the palette, the File menu,
/// `cmux home invite-to-team --email …` and MCP. The dialog shows over `window` on the input's own
/// turn (no switch to Home: an invite has no conversation to show), reads what a join costs the
/// team while it shows, and sends only on the person's Send. A CLI or agent run opens it prefilled
/// with a line that an agent asked, and its result is the person's answer. The server path is the
/// team API's `POST /api/teams/:id/invitations` (``CloudAuth/inviteToTeam(id:emails:)``), the one
/// Settings > Accounts' team calls use.
///
/// ```swift
/// registry.bindEffect("home.inviteToTeam", unavailable: reason) { invocation in
///     HomeTeamInviteRun(auth: cloud.auth, teamID: team.id, teamName: team.displayName).effect(invocation, over: window)
/// }
/// ```
@MainActor
public struct HomeTeamInviteRun {
    private let auth: CloudAuth
    private let teamID: String
    private let teamName: String

    /// - Parameters:
    ///   - auth: The signed-in account that sends the invite.
    ///   - teamID: The active team's id.
    ///   - teamName: Its name, for the dialog.
    public init(auth: CloudAuth, teamID: String, teamName: String) {
        self.auth = auth
        self.teamID = teamID
        self.teamName = teamName
    }

    /// Shows the dialog now and answers when it closes.
    ///
    /// - Parameters:
    ///   - invocation: The run; its optional `email` prefills the dialog.
    ///   - window: The window the dialog blocks.
    /// - Returns: `.refused` for a malformed `email`, else the shown dialog whose result is
    ///   `sent` and `team`, or (for a CLI or agent run) a refusal when the person cancels.
    public func effect(_ invocation: ActionInvocation, over window: NSWindow) -> ActionEffect {
        let raw = invocation["email"]?.stringValue ?? ""
        let check: EmailCheck = HomeComposeRules().call("team.inviteEmail", EmailCheck.Request(text: raw),
                                                      fallback: EmailCheck(prefill: raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        if let refused = check.refused {
            return .refused(HomeComposeOutcome.invalidAddress(refused.text).message ?? refused.text)
        }
        let text = check.prefill ?? ""
        let byPerson = invocation.origin == .user
        let sheet = HomeTeamInviteSheet(team: teamName, prefill: text, requestedByAgent: !byPerson)
        let auth = auth, teamID = teamID
        sheet.seatImpact = { await Self.seatImpact(of: teamID, auth: auth) }
        var sent: String?
        sheet.onSend = { address in
            let outcome = await Self.invite(address, to: teamID, auth: auth)
            if case .invited = outcome { sent = address.description }
            return outcome
        }
        // One answer, yielded once when the dialog closes.
        let (answers, answer) = AsyncStream<String?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        sheet.onFinish = { _ in
            answer.yield(sent)
            answer.finish()
        }
        HomeSheetPresenter().present(sheet, over: window)
        return .applied(result: {
            for await email in answers {
                guard let email else { break }
                return .success(["sent": .string(email), "team": .string(teamID)])
            }
            // The person's own Cancel is no failure; an agent hears that nothing was sent.
            if byPerson { return .success(["cancelled": .bool(true), "team": .string(teamID)]) }
            return .failure(ActionWorkFailure(refusal: .unavailable, reason: HomeTeamInviteFailure.cancelled.message))
        })
    }

    /// What a join costs `teamID`, from the team API's detail.
    static func seatImpact(of teamID: String, auth: CloudAuth) async -> HomeTeamSeatImpact {
        guard let facts = await auth.seatFacts(teamID: teamID) else { return .unknown }
        return HomeTeamSeatImpact.of(canInvite: facts.canInvite, planID: facts.planID, hasSubscription: facts.hasSubscription,
                                     memberCount: facts.memberCount, memberLimit: facts.memberLimit)
    }

    /// Sends one invite and says how it went, in the dialog's outcome words.
    static func invite(_ address: ContactAddress, to teamID: String, auth: CloudAuth) async -> HomeComposeOutcome {
        let email = address.description
        let result: InviteResult = switch await auth.inviteOne(email, toTeam: teamID) {
        case .sent: InviteResult(kind: "sent")
        case .alreadyMember: InviteResult(kind: "alreadyMember", email: email)
        case .sendFailed: InviteResult(kind: "sendFailed", email: email)
        case .notAllowed: InviteResult(kind: "notAllowed")
        case .unreachable: InviteResult(kind: "unreachable")
        }
        let outcome: InviteOutcome = HomeComposeRules().call("team.inviteOutcome", ["result": result],
                                                           fallback: InviteOutcome(kind: "cloudUnreachable"))
        switch outcome.kind {
        case "invited": return .invited(nil)
        case "refused":
            let failure: HomeTeamInviteFailure = switch outcome.reason?.kind {
            case "alreadyMember": .alreadyMember(outcome.reason?.email ?? email)
            case "sendFailed": .sendFailed(outcome.reason?.email ?? email)
            default: .notAllowed
            }
            return .refused(failure.message)
        default: return .cloudUnreachable
        }
    }

    /// `compose.team.inviteEmail`'s reply: the trimmed prefill, or the address it refuses.
    private struct EmailCheck: Decodable {
        struct Request: Encodable { var text: String }
        struct Refused: Decodable { var text: String }

        var refused: Refused?
        var prefill: String?
    }

    /// `compose.team.inviteOutcome`'s request (`InviteResult`) and reply.
    private struct InviteResult: Encodable {
        var kind: String
        var email: String?
    }

    private struct InviteOutcome: Decodable {
        struct Reason: Decodable {
            var kind: String
            var email: String?
        }

        var kind: String
        var reason: Reason?
    }
}
