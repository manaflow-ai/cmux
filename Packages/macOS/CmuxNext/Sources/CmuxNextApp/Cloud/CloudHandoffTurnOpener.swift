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
    /// The session it names must be the one recorded on the pane's tab (``ownsSession(recorded:asked:)``),
    /// never only what the page says: a new chat whose session is not bound to its tab yet is refused,
    /// and its prompt goes under its own id.
    /// The pane's chat and its machine are read before the store's calls and again after them: an
    /// answer for a pane that moved to another chat or machine meanwhile names no turn and starts no
    /// watch. The gate (``refusal(_:)``) is read before any store call, so a refused ask posts nothing.
    static func runner(_ tabs: AgentTabStore, services: AppServices) -> @MainActor (AgentPaneView?, String) async -> [String: Any] {
        { [weak tabs, weak services] view, session in
            guard let services else { return AgentPaneReply.failure(code: "cloud_disabled", message: "cloud_disabled") }
            if let refusal = refusal(services) { return AgentPaneReply.failure(code: refusal, message: refusal) }
            let place = { () -> (tab: String, machine: String, host: String?)? in
                guard let view, let key = tabs?.views.first(where: { $0.value === view })?.key, let (tab, _) = services.locateTab(key),
                      view.model.sessionId == nil || view.model.sessionId == session,
                      ownsSession(recorded: tab.agentSession?.session, asked: session),
                      let daemon = try? services.machines.agentDaemon(forTab: tab), !daemon.isLocal,
                      let machine = services.machines.session(daemon.machineID)?.machineID else { return nil }
                return (tab.id, machine, tab.agentSession?.host)
            }
            guard let before = place() else { return AgentPaneReply.failure(code: "not_cloud", message: "not_cloud") }
            let opened = await CloudHandoffTurnOpener(services: services).reply(session: session, machine: before.machine)
            guard case .turn(let id, let number) = opened else { return Self.answer(opened) }
            // A team switch meanwhile leaves no current list: the turn is not named under it.
            guard refusal(services) == nil, let after = place(), after.tab == before.tab, after.machine == before.machine else {
                return AgentPaneReply.failure(code: "not_cloud", message: "not_cloud")
            }
            services.agentTabs.pageChats.handoffNotices?.watch(handoff: id, session: session, host: before.host)
            return AgentPaneReply.success(["turn": number])
        }
    }

    /// Whether a pane may name hand-off turns for `asked`: only the acpmux session recorded on its
    /// tab (`bind-conversation-tab-session`), so a page cannot open a hand-off for a session it
    /// does not show.
    nonisolated static func ownsSession(recorded: String?, asked: String) -> Bool {
        guard let recorded, !recorded.isEmpty else { return false }
        return recorded == asked
    }

    /// The store's answer for `session` on `machine`, or a refusal code.
    func reply(session: String, machine: String) async -> Opened {
        do {
            return try await Self.open(session: session, machine: machine, client: ownerClient())
        } catch {
            services.cloud.logger.error("hand-off turn not opened: \(CloudStrings.errorText(error), privacy: .public)")
            return .refused(Self.storeCode(error) ?? "handoff.unavailable")
        }
    }

    /// The page's reply for a refusal (a turn is answered once its pane is checked again).
    static func answer(_ opened: Opened) -> [String: Any] {
        switch opened {
        case .turn(_, let number): return AgentPaneReply.success(["turn": number])
        case .refused(let code): return AgentPaneReply.failure(code: code, message: code)
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
                // The store may close the hand-off after the create but before this POST. Its
                // refusal carries the current hand-off (whose turn still equals `after`), so
                // preserve that authoritative code before validating the normal success shape.
                if begun.state == "closed" { return .refused("handoff.closed") }
                if let refusal = begun.refusal, refusal != "handoff.turn_conflict" { return .refused(refusal) }
                guard begun.id == handoff.id, begun.sessionId == session, begun.machine == machine, begun.turn > after else {
                    return .refused("handoff.turn_conflict")
                }
                handoff = begun
            }
        }
        // The last begin's answer is read too: a turn it made is named, never left unreported.
        if case .name(let turn) = handoff.next { return .turn(id: handoff.id, number: turn) }
        return .refused("handoff.turn_conflict")
    }

    /// Why no hand-off turn opens at all now: Cloud off by policy, Labs off, not signed in (the
    /// codes a Sandboxed send answers, ``AgentPageChats/wireSandbox(_:services:)``), or a machine
    /// list not loaded for the account signed in now (``CloudService/hasLoadedCurrentMachines``).
    static func refusal(_ services: AppServices) -> String? {
        refusal(cloudAllowed: !services.registry.disabledFeatures.contains(.cloud) && services.cloud.mayCallCloud,
                labs: services.settings?.snapshot.previewFeatures == true,
                signedIn: services.cloud.isSignedIn, loadedCurrent: services.cloud.hasLoadedCurrentMachines)
    }

    /// ``refusal(_:)`` over what it reads. After a team switch the previous team's machines stay in
    /// the store until this team's list lands, and the store's create checks only the machine id's
    /// shape: a hand-off is never made for a machine of a list not loaded for the account now.
    nonisolated static func refusal(cloudAllowed: Bool, labs: Bool, signedIn: Bool, loadedCurrent: Bool) -> String? {
        if !cloudAllowed { return "cloud_disabled" }
        if !labs { return "labs_off" }
        if !signedIn { return "not_signed_in" }
        return loadedCurrent ? nil : "machines_unread"
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
