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
        func shareOwnerToken() async -> String? {
            tokenAsked = true
            return "owner-token"
        }
        func shareCopy(_ text: String) {}
        func shareNotice(_ message: String) {}
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
        if case .failure(let failure) = result { #expect(failure.code != "share.declined") }
    }
}
