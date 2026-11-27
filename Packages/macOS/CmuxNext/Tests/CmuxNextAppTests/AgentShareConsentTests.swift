import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextDaemonService
import Testing

/// #30263: a guest link exposes a chat's whole transcript, so only its owner may make one. A run the
/// owner did not start in the app (the CLI, MCP, a script, a page, another client, or any control
/// socket run, whatever origin it claims) waits for the owner's answer in the app before the owner's
/// token is spent or a link exists; a declined ask makes no link.
@MainActor @Suite(.serialized)
struct AgentShareConsentTests {
    /// Forwards the chat lookups to the fixture's services; no daemon is connected, so a run that gets
    /// past the owner's token fails `not connected`. Records whether the token was asked for.
    @MainActor final class Host: AgentShareHost {
        let services: AppServices
        var tokenAsked = false

        init(_ services: AppServices) { self.services = services }

        func shareTab(surface: SurfaceID) -> TabModel? { services.shareTab(surface: surface) }
        func shareTab(id: String) -> TabModel? { services.shareTab(id: id) }
        func shareTabID(showing session: String) -> String? { services.shareTabID(showing: session) }
        var shareFocusedTabID: String? { nil }
        func shareConnection(holding tab: TabModel) -> DaemonConnection? { nil }
        func shareIsOnThisMac(_ tab: TabModel) -> Bool { true }
        var shareLocalConnection: DaemonConnection? { nil }
        func shareOwnerToken(api: URL?) async -> String? {
            tokenAsked = true
            return "owner-token"
        }
        func shareCopy(_ text: String) {}
        func shareNotice(_ message: String) {}
        /// The owner's answer to the consent sheet; nil leaves the protocol's default (no).
        var answer: Bool?
        var asks: [AgentShareConsentAsk] = []
        func shareAskOwner(_ ask: AgentShareConsentAsk) async -> Bool {
            asks.append(ask)
            return answer ?? false
        }
    }

    static func run(_ registry: ActionRegistry, origin: ActionOrigin, viaSocket: Bool = false) async -> Result<[String: ActionResultValue], ActionWorkFailure>? {
        var invocation = ActionInvocation(target: nil, arguments: ["surface": .int(1)], origin: origin)
        invocation.viaControlSocket = viaSocket
        let run = registry.capturingRun { _ = registry.perform(AgentShareActions.share, invocation: invocation) }
        guard let result = run.results.first else { return nil }
        return await result.value
    }

    /// With no consent sheet (this host answers nothing), every run the owner did not start makes no
    /// link and never spends the owner's token. A socket run's `user` origin is a claim, not the owner.
    @Test func aRunTheOwnerDidNotStartMakesNoLinkWithoutTheirYes() async {
        let f = AgentShareTests.fixture()
        let host = Host(f.services)
        let registry = ActionRegistry.standard()
        AgentShareActions(host: host).bind(into: registry)
        let runs: [(ActionOrigin, Bool)] = [(.mcp, true), (.cli, true), (.script, true), (.page, false), (.remote, true), (.user, true)]
        for (origin, viaSocket) in runs {
            host.tokenAsked = false
            guard case .failure(let failure) = await Self.run(registry, origin: origin, viaSocket: viaSocket) else {
                Issue.record("\(origin) (socket \(viaSocket)) made a link with no owner consent"); continue
            }
            #expect(!host.tokenAsked, "\(origin) (socket \(viaSocket)) spent the owner's token before the owner said yes")
            #expect(failure.code == "share.declined", "\(origin) (socket \(viaSocket)) failed for another reason: \(failure.message)")
        }
    }

    /// The owner's own palette or menu run is their consent: it asks nothing and goes on to the daemon.
    @Test func theOwnersOwnRunAsksNothing() async {
        let f = AgentShareTests.fixture()
        let host = Host(f.services)
        let registry = ActionRegistry.standard()
        AgentShareActions(host: host).bind(into: registry)
        let result = await Self.run(registry, origin: .user)
        #expect(host.tokenAsked, "the owner's own run did not reach the daemon")
        #expect(host.asks.isEmpty, "the owner's own run asked them")
        if case .failure(let failure) = result { #expect(failure.code != "share.declined") }
    }

    /// The owner's Allow lets an agent's run go on to the daemon, and the sheet names the chat, how
    /// long the link lasts and how many times it works.
    @Test func theOwnersAllowLetsAnAgentsRunGoOn() async {
        let f = AgentShareTests.fixture()
        let host = Host(f.services)
        host.answer = true
        let registry = ActionRegistry.standard()
        AgentShareActions(host: host).bind(into: registry)
        var invocation = ActionInvocation(target: nil, arguments: ["surface": .int(1), "ttl": .string("2h"), "uses": .int(3)], origin: .mcp)
        invocation.viaControlSocket = true
        let run = registry.capturingRun { _ = registry.perform(AgentShareActions.share, invocation: invocation) }
        let result = await run.results.first?.value
        #expect(host.tokenAsked, "the owner allowed it, but the run stopped before the daemon")
        if case .failure(let failure)? = result { #expect(failure.code != "share.declined") }
        #expect(host.asks == [AgentShareConsentAsk(chat: "Fix the build", ttlSecs: 7200, uses: 3)])
        let ask = AgentShareConsentAsk(chat: "Fix the build", ttlSecs: nil, uses: nil)
        #expect(ask.title.contains("Fix the build"))
        #expect(ask.lines.count == 2)
    }

    /// The sheet is a cmux dialog whose Return presses nothing: Allow is a deliberate click.
    @Test func theSheetsAllowIsNotTheReturnKey() {
        let spec = AgentShareConsentSheet.spec(AgentShareConsentAsk(chat: "Fix the build", ttlSecs: nil, uses: nil))
        #expect(spec.buttons.map(\.id) == ["cancel", "allow"])
        #expect(spec.buttons.allSatisfy { $0.role != .default })
        // The debug socket's dialog press never answers it: the asking script cannot approve its own link.
        #expect(spec.identifier == AgentShareConsentSheet.identifier)
        #expect(DebugDialog.userOnly.contains(AgentShareConsentSheet.identifier))
    }

    /// A run the agent made from its own chat asks, even when it claims the `user` origin.
    @Test func anAgentsOwnChatRunAsks() {
        var invocation = ActionInvocation(target: nil, arguments: [:], origin: .user)
        #expect(AgentShareActions.ownerStarted(invocation))
        invocation.callerAgentSession = AgentShareTests.session
        #expect(!AgentShareActions.ownerStarted(invocation))
        invocation.callerAgentSession = nil
        invocation.viaControlSocket = true
        #expect(!AgentShareActions.ownerStarted(invocation))
        invocation.viaControlSocket = false
        invocation.callerApp = "com.example.helper"
        #expect(!AgentShareActions.ownerStarted(invocation), "a run naming a calling app is not the owner's gesture")
    }

    /// An Allow at the sheet's last second still gets the daemon's create inside the caller's deadline.
    @Test func theSheetClosesBeforeTheCallerGivesUp() {
        #expect(AgentShareConsentSheet.answerWithin + AgentShareActions.createDeadline < ActionDescriptor.personDeadline)
        #expect(ActionRegistry.standard().descriptor(for: AgentShareActions.share)?.waitsForPerson == true)
    }

    static func invite(_ registry: ActionRegistry, origin: ActionOrigin, viaSocket: Bool = true,
                       role: String? = nil) async -> Result<[String: ActionResultValue], ActionWorkFailure>? {
        var arguments: [String: ActionValue] = ["surface": .int(1), "account": .string("leo@cmux.com")]
        if let role { arguments["role"] = .string(role) }
        var invocation = ActionInvocation(target: nil, arguments: arguments, origin: origin)
        invocation.viaControlSocket = viaSocket
        let run = registry.capturingRun { _ = registry.perform(AgentShareActions.invite, invocation: invocation) }
        guard let result = run.results.first else { return nil }
        return await result.value
    }

    /// An invite opens the chat to an account as surely as a link: a run the owner did not start
    /// invites nobody, and makes no share, without their yes.
    @Test func anInviteTheOwnerDidNotStartWaitsForTheirYes() async {
        let f = AgentShareTests.fixture()
        let host = Host(f.services)
        let registry = ActionRegistry.standard()
        AgentShareActions(host: host).bind(into: registry)
        for origin in [ActionOrigin.mcp, .cli, .script, .user] {
            host.tokenAsked = false
            guard case .failure(let failure)? = await Self.invite(registry, origin: origin) else {
                Issue.record("\(origin) invited someone with no owner consent"); continue
            }
            #expect(failure.code == "share.declined", "\(origin): \(failure.message)")
            #expect(failure.message == AgentShareStrings.inviteDeclined)
            #expect(!host.tokenAsked, "\(origin) spent the owner's token before the owner said yes")
        }
        // The owner's Allow lets it go on to the daemon; the sheet names who and what they may do.
        host.answer = true
        host.asks = []
        let allowed = await Self.invite(registry, origin: .mcp, role: "view")
        if case .failure(let failure)? = allowed { #expect(failure.code != "share.declined") }
        let ask = AgentShareConsentAsk(chat: "Fix the build", ttlSecs: nil, uses: nil, invite: .init(account: "leo@cmux.com", role: "view"))
        #expect(host.asks == [ask])
        #expect(ask.title.contains("leo@cmux.com") && ask.title.contains("Fix the build"))
        #expect(ask.lines == [AgentShareStrings.inviteConsentDetail, AgentShareStrings.inviteRoleLine("view")])
        #expect(ask.allowTitle == AgentShareStrings.inviteConsentAllow && ask.declineTitle == AgentShareStrings.inviteConsentDecline)
        #expect(ActionRegistry.standard().descriptor(for: AgentShareActions.invite)?.waitsForPerson == true)
    }

    /// The owner's own palette run of Invite People asks nothing.
    @Test func theOwnersOwnInviteAsksNothing() async {
        let f = AgentShareTests.fixture()
        let host = Host(f.services)
        let registry = ActionRegistry.standard()
        AgentShareActions(host: host).bind(into: registry)
        let result = await Self.invite(registry, origin: .user, viaSocket: false)
        #expect(host.asks.isEmpty, "the owner's own invite asked them")
        if case .failure(let failure)? = result { #expect(failure.code != "share.declined") }
    }

    /// An invite with no account, or a role that is neither view nor talk, is refused before anything runs.
    @Test func anInviteNamesAnAccountAndARole() {
        let f = AgentShareTests.fixture()
        let registry = f.services.registry
        var cli = ActionInvocation(target: nil, arguments: ["surface": .int(1)], origin: .cli)
        cli.viaControlSocket = true
        let none = registry.capturingTypedRefusal { _ = registry.perform(AgentShareActions.invite, invocation: cli) }
        #expect(none?.reason == AgentShareStrings.needsAccount, "a CLI invite with no account ran")
        let uninvite = registry.capturingTypedRefusal {
            _ = registry.perform(AgentShareActions.uninvite, invocation: ActionInvocation(target: nil, arguments: ["surface": .int(1)], origin: .cli))
        }
        #expect(uninvite != nil, "an uninvite with no account ran")
        let role = registry.capturingTypedRefusal {
            _ = registry.perform(AgentShareActions.invite, invocation: ActionInvocation(
                target: nil, arguments: ["surface": .int(1), "account": .string("leo@cmux.com"), "role": .string("admin")], origin: .cli))
        }
        #expect(role?.reason == AgentShareStrings.badRole)
    }
}
