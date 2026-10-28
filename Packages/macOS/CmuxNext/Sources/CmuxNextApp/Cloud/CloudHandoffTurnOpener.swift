import CmuxNextAgentPane
import CmuxNextCloud
import Foundation

/// `cloud.handoffTurn {sessionId}`: the owner side of a Cloud chat's hand-off (cloud work mode,
/// leo-workspace design/cloud-work-mode.md). Before a prompt that starts a turn goes to a chat on
/// one of the account's Cloud machines, the page asks for the turn it names: the session's hand-off
/// is made at its first turn, the next turn begins once the last one ended, and a turn made or begun
/// but not run yet is named again. The page sends the prompt as `handoff-<turn>-<id>`; acpmux on the
/// machine reports that turn (running, needs-you, done, failed), and ``HandoffNotices`` follows the
/// hand-off and tells the person.
///
/// Behind Labs preview features, like the composer's Cloud row. A turn that runs or waits for the
/// person, a closed hand-off, Cloud off, or a chat not on a Cloud machine answers a refusal code,
/// and the page sends the prompt under its own id (it runs as before; only its report is missing).
@MainActor
struct CloudHandoffTurnOpener {
    let services: AppServices

    /// The page's runner for every pane (``AgentPageChats/seed(_:)``): `view` is the pane that asked.
    static func runner(_ tabs: AgentTabStore, services: AppServices) -> @MainActor (AgentPaneView?, String) async -> [String: Any] {
        { [weak tabs, weak services] view, session in
            guard let services else { return AgentPaneReply.failure(code: "cloud_disabled", message: "cloud_disabled") }
            if let refusal = refusal(services) { return AgentPaneReply.failure(code: refusal, message: refusal) }
            guard let view, let key = tabs?.views.first(where: { $0.value === view })?.key, let (tab, _) = services.locateTab(key),
                  let daemon = try? services.machines.agentDaemon(forTab: tab), !daemon.isLocal,
                  let machine = services.machines.session(daemon.machineID)?.machineID else {
                return AgentPaneReply.failure(code: "not_cloud", message: "not_cloud")
            }
            return await CloudHandoffTurnOpener(services: services).reply(session: session, machine: machine, host: tab.agentSession?.host)
        }
    }

    /// The page's reply: `{turn}`, or a refusal code.
    func reply(session: String, machine: String, host: String?) async -> [String: Any] {
        do {
            switch try await Self.open(session: session, machine: machine, client: ownerClient()) {
            case .turn(let id, let number):
                services.agentTabs.pageChats.handoffNotices?.watch(handoff: id, session: session, host: host)
                return AgentPaneReply.success(["turn": number])
            case .refused(let code):
                return AgentPaneReply.failure(code: code, message: code)
            }
        } catch {
            services.cloud.logger.error("hand-off turn not opened: \(CloudStrings.errorText(error), privacy: .public)")
            let code = Self.storeCode(error) ?? "handoff.unavailable"
            return AgentPaneReply.failure(code: code, message: code)
        }
    }

    /// What ``open(session:machine:client:)`` found: the turn a prompt names, or why none.
    enum Opened: Equatable {
        case turn(id: String, number: Int)
        /// `handoff.conflict` (the session's hand-off is on another machine), `handoff.closed`,
        /// `handoff.turn_running` (a turn runs or waits for the person) or `handoff.turn_conflict`
        /// (other devices kept beginning turns).
        case refused(String)
    }

    /// The turn a prompt of `session` on `machine` names: the session's hand-off is made or read, then
    /// its current turn is named when it has not run yet, or the next one begins once it ended.
    static func open(session: String, machine: String, client: CloudOwnerAPIClient) async throws -> Opened {
        try await open(session: session, machine: machine,
                       make: { try await client.handoffOpen(session: $0, machine: $1) },
                       begin: { try await client.handoffBeginTurn($0, after: $1) })
    }

    /// ``open(session:machine:client:)`` over its two calls (tests stand in for the store).
    static func open(session: String, machine: String,
                     make: (String, String) async throws -> CloudHandoffTurn,
                     begin: (String, Int) async throws -> CloudHandoffTurn) async throws -> Opened {
        var handoff = try await make(session, machine)
        // One hand-off per session, made with this machine: one on another machine (a chat moved
        // since) is not this chat's turn to name.
        guard handoff.sessionId == session, handoff.machine == machine, handoff.refusal != "handoff.conflict" else {
            return .refused("handoff.conflict")
        }
        // Another device may begin (and even finish) the next turn first (`turn_conflict` answers
        // the hand-off as it is): its turn is named while it has not run yet, and one that already
        // ended begins the one after. A few tries, then the prompt goes unnamed.
        for _ in 0..<3 {
            switch handoff.next {
            case .name(let turn): return .turn(id: handoff.id, number: turn)
            case .none: return .refused(handoff.state == "closed" ? "handoff.closed" : "handoff.turn_running")
            case .begin(let after):
                let begun = try await begin(handoff.id, after)
                guard begun.id == handoff.id, begun.sessionId == session, begun.machine == machine, begun.turn > after else {
                    return .refused("handoff.turn_conflict")
                }
                handoff = begun
            }
        }
        return .refused("handoff.turn_conflict")
    }

    /// Why no hand-off turn opens at all now: Cloud off by policy, Labs off, or not signed in (the
    /// codes a Sandboxed send answers, ``AgentPageChats/wireSandbox(_:services:)``).
    static func refusal(_ services: AppServices) -> String? {
        if services.registry.disabledFeatures.contains(.cloud) || !services.cloud.mayCallCloud { return "cloud_disabled" }
        if services.settings?.snapshot.previewFeatures != true { return "labs_off" }
        return services.cloud.isSignedIn ? nil : "not_signed_in"
    }

    /// The store's own refusal code (`handoff.closed`, `rate_limited`, …), the only text the page gets.
    static func storeCode(_ error: any Error) -> String? {
        guard case .http(_, let code?, _, _, _) = error as? CloudAPIError,
              code.range(of: #"^[a-z_.]{1,64}$"#, options: .regularExpression) != nil else { return nil }
        return code
    }

    /// The person's own session on the backend API, as ``HandoffNotices`` reads hand-offs.
    private func ownerClient() -> CloudOwnerAPIClient {
        let cloud = services.cloud, auth = cloud.auth, identity = cloud.installIdentity
        return CloudOwnerAPIClient(
            baseURL: FeedService.apiBaseURL(auth: auth),
            accessToken: { try await auth.tokens().access },
            teamID: { (try? await identity.installToken()).flatMap(MacInstallIdentity.team(ofToken:)) }
        )
    }
}
