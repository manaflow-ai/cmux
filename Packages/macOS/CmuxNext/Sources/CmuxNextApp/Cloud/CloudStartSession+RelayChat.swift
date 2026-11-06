import CmuxNextActions
import CmuxNextCloud
import CmuxNextCloudCredentials
import CmuxNextCloudUI
import Foundation

/// `cmux cloud relay-chat` (cmuxterm-hq#7086; Leo: "it should take <30 seconds from starting a thing to having a response on
/// cloud"): sends a prompt to an agent on a Cloud machine over its relay (``CloudRelayChat``) in the order link, owner check, login,
/// send (cmux#36846: a cold machine's link from this Mac and its owner answer, ``RelaySteps/link``, come before the login and the send),
/// and answers when the turn ends (its acpmux session, the reply, the first text's time) or within ``CloudHandlers/answerWithin`` with
/// what came so far. `delivered` false: the prompt certainly never reached the machine. `cmux cloud start-chat` uses it first. A turn
/// still running when this answers keeps its stream until it ends; quitting the app cancels it on the machine.
///
/// Before the send the machine takes the person's harness login as start-session's start does (``passHarnessLogin(_:agent:login:still:)``;
/// Leo: "we have the daemon, we have the token, we have the thing that can just send it over the authentication"). A login
/// the rules refuse, or one the machine still lacks, sends nothing (``relayLoginRefusal(_:_:machine:ownership:)``).
///
/// The person's own run only: an agent starts a Cloud chat with `cloud start-session`, which asks the person first.
extension CloudStartSession {
    /// The relay chat's two steps on the network: the machine's harness login, then the relay itself. Tests stand in for both.
    struct RelaySteps {
        /// Runs ``passHarnessLogin(_:agent:login:still:)`` on the machine; it leaves its decision on `harnessLogin`.
        var login: @MainActor (CloudMachineSession, Request, _ still: () throws -> Void) async throws -> Void
        var relay: @MainActor () -> CloudRelayChat?
        /// How long a CLI or MCP run waits for `link` and `login` before it answers without sending.
        var loginWithin: Duration = CloudStartSession.loginWithin
        /// The app link up before the login, as start-session connects first, so the login reads its owner answer (false: none came up).
        var link: @MainActor (CloudMachineSession) async -> Bool = { $0.appLink == nil ? true : await $0.linkHop(origin: .script) }
        var account: (@MainActor () -> [String?])? // the signed-in account now; nil: the Cloud service's (a test switches it)
        static func live(_ services: AppServices) -> RelaySteps { RelaySteps(login: { try await CloudStartSession(services: services).passHarnessLogin($0, agent: $1.agent, login: $1.login, still: $2) }, relay: { services.cloud.relayChat }) }
    }

    static func bindRelayChat(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?,
                              steps: RelaySteps? = nil) {
        let cloud = context.services.cloud, steps = steps ?? .live(context.services), now = { steps.account?() ?? cloud.account }
        // action-wait-allow: the reply comes from the machine over the network; nothing local can stand in for it.
        CloudHandlers.bind("cloudRelayChat", registry, reason: reason) { invocation in
            // A refusal here sent nothing: it answers undelivered, so `cloud start-chat` goes the start-session way,
            // which asks an agent's person and words the same refusals.
            let machine: CloudMachineSession, started: Request, prompt: String
            do {
                guard !isAgent(invocation) else { throw ActionFailure(message: CloudStartSessionStrings.relayAgentRun) }
                machine = try CloudHandlers.machine(invocation, context)
                // The agent and the folder, checked as `cloud start-session` checks them.
                started = try request(invocation)
                prompt = invocation["prompt"]?.stringValue ?? ""
                guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ActionFailure(message: CloudStartSessionStrings.relayPromptRequired)
                }
            } catch let refusal as ActionFailure {
                // A person's own run (the palette) sees the refusal; a CLI or MCP run gets it as an undelivered answer.
                if CloudHandlers.origin(of: invocation) == .user { throw refusal }
                let code = isAgent(invocation) ? "cloud.relay.agent_run" : "cloud.relay.refused"
                return CloudHandlers.result("cloud relay chat", context) { notSent(code, refusal.message) }
            }
            let machineID = machine.machineID, account = now()
            let promptID = (invocation["promptId"]?.stringValue?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            let login: @MainActor () async throws -> (code: String, message: String)? = {
                // This entry never resumes a paused or resuming machine (it outlasts 15 s): no login, no send; start-chat's start-session resumes it.
                if machine.machine.status == .paused || machine.machine.shownStatus.isChanging { return ("cloud.relay.machine_not_ready", CloudStartSessionStrings.notConnected(machine.machine.title, id: machineID, agent: started.agent)) }
                // Link, owner check, login, send: a cold machine's link and owner answer come first (none: no login, no send); after the link's wait the account again, and a run not yet answered.
                let linking = ContinuousClock.now, asked = started.asked(machine: machine.machine.title)
                try Self.checked(account, now: now(), asked)
                guard await steps.link(machine) else { return ("cloud.relay.not_connected", CloudStartSessionStrings.notConnected(machine.machine.title, id: machineID, agent: started.agent)) }
                try Self.checked(account, now: now(), asked); guard ContinuousClock.now - linking < steps.loginWithin else { return ("cloud.relay.login_pending", CloudStartSessionStrings.relayLoginPending(asked)) }
                try await steps.login(machine, started) { try Self.checked(account, now: now(), asked) }
                let link = machine.appLink, ownership = await link?.callerOwnership ?? .unknown, state = await link?.stateWord ?? "none", decision = machine.harnessLogin
                let refusal = relayLoginRefusal(decision, started, machine: machine.machine.title, ownership: ownership)
                let cached = decision.map { $0.machineProbe == nil && $0.machineLogin == nil ? "unqueried" : $0.cached ? "yes" : "no" } ?? "unqueried" // verdicts only: no id, token, path or provider output
                cloud.logger.info("cloud relay chat: harness login \(refusal?.code ?? "ready", privacy: .public): link \(state, privacy: .public), owner \(ownership.rawValue, privacy: .public), guest \(decision?.guestKind ?? "-", privacy: .public), cached \(cached, privacy: .public) (\(decision?.summary ?? "no step", privacy: .public))")
                return refusal
            }
            // A person's run waits for the whole turn and shows the reply, or why there is none.
            guard CloudHandlers.origin(of: invocation) != .user else {
                return CloudHandlers.runTracked("cloud relay chat", context) {
                    guard let relay = steps.relay() else { throw ActionFailure(message: CloudStartSessionStrings.relayUnavailable) }
                    if let refusal = try await login() { throw ActionFailure(message: refusal.message) }
                    try Self.checked(account, now: now(), started.asked(machine: machine.machine.title)); let answer = try await relay.chat(machineID, agent: started.agent, prompt: prompt, cwd: started.cwd, promptID: promptID)
                    let text = answer.errorMessage.map { answer.reply.isEmpty ? $0 : answer.reply + "\n\n" + $0 } ?? answer.reply
                    CloudPresenter.show(CloudStartSessionStrings.relayReplyTitle, text, copyable: true, in: CloudHandlers.window(context))
                }
            }
            CloudHandlers.result("cloud relay chat", context) {
                guard let relay = steps.relay() else { return notSent("cloud.relay.unavailable", CloudStartSessionStrings.relayUnavailable) }
                let clock = ContinuousClock(), begun = clock.now, asked = started.asked(machine: machine.machine.title)
                // Link and login get `loginWithin` of the deadline (still running: nothing sent). A refusal's command recovers: the caller's
                // `--login`, else `--login none` (a bare rerun refuses again), whose chat signs in.
                let refused = { (code: String, message: String) in notSent(code, message).merging(["command": .string(asked.command)]) { $1 } }
                let decided: (code: String, message: String)??
                do { decided = try await Self.first(within: steps.loginWithin, login); try Self.checked(account, now: now(), asked) } catch let failure as ActionFailure { return refused("cloud.relay.login_account_changed", failure.message) }
                guard let refusal = decided else { return refused("cloud.relay.login_pending", CloudStartSessionStrings.relayLoginPending(asked)) }
                if let refusal { let reason = machine.harnessLogin?.reason; return refused(refusal.code, refusal.message).merging(["command": .string(asked.command + ([.needsLoginChoice, .machineLoginMissing].contains(reason) ? " --login none" : ""))].merging(reason.map { ["login_reason": .string($0.rawValue)] } ?? [:]) { $1 }) { $1 } }
                let linked = clock.now - begun, answer = try await relay.answer(machineID, agent: started.agent, prompt: prompt, cwd: started.cwd,
                                                                                 promptID: promptID, within: CloudHandlers.answerWithin - linked)
                return relayFields(answer, machineID: machineID, linkLogin: linked)
            }
        }
    }

    /// Why the relay sends nothing after the login step (`decision`, nil when none ran), in fixed text; nil sends. Ownership first, for every agent: `team` never takes a chat here (cmux#29214),
    /// `unknown` (no link too) is `login_unverified`; only an `owner` goes on: a refusal, a login this Mac lacks, declined or failed, and a Claude skip without the machine's own login or `--login none`.
    static func relayLoginRefusal(_ decision: CloudHarnessLoginDecision?, _ started: Request, machine: String,
                                  ownership: CloudCallerOwnership) -> (code: String, message: String)? {
        let asked = started.asked(machine: machine)
        if ownership == .team { return ("cloud.relay.login_team_machine", AgentRemoteStartRefusal.teamMachine(machine: machine).userMessage) }
        guard ownership == .owner else { return ("cloud.relay.login_unverified", CloudStartSessionStrings.relayLoginUnverified(asked)) }
        guard let decision else { return nil }
        if let reason = decision.refusal { return ("cloud.relay.login_refused", CloudStartSessionStrings.loginRefused(Self.loginRefusal(reason), asked)) }
        // No login copied to a machine that needs one: none cached on this Mac, or the person said no to its copy (the confirm or Release's consent, after the cache check).
        if decision.outcome == CloudStartChat.loginDeclined { return ("cloud.relay.login_declined", CloudStartSessionStrings.relayLoginDeclined(asked)) }
        if CloudStartChat.signInOnMachine.contains(decision.outcome) { return ("cloud.relay.login_missing", CloudStartSessionStrings.relayLoginMissing(asked)) }
        if decision.outcome == CloudStartChat.loginCancelled { return ("cloud.relay.login_cancelled", CloudStartSessionStrings.relayLoginCancelled(asked)) } // its step never finished
        if let outcome = decision.outcome, outcome.hasPrefix(CloudStartChat.loginFailed) {
            return ("cloud.relay.login_failed", CloudStartSessionStrings.relayLoginFailed(asked, reason: Self.reason(String(outcome.dropFirst(CloudStartChat.loginFailed.count)))))
        }
        guard decision.provider == .claude, decision.step == .skip, decision.outcome == nil, ![.machineLoginKept, .choseNone].contains(decision.reason) else { return nil }
        if decision.reason == .callerNotOwner { return ("cloud.relay.login_unverified", CloudStartSessionStrings.relayLoginUnverified(asked)) }
        return ("cloud.relay.login_skipped", CloudStartSessionStrings.relayLoginSkipped(asked))
    }

    /// How long a CLI or MCP relay chat waits for the login step: well inside ``CloudHandlers/answerWithin``, so the turn keeps 20 s.
    static let loginWithin: Duration = .seconds(15)

    /// `work`'s answer if it comes within `wait`, else nil (the work goes on to its end). Its error is thrown.
    static func first<T: Sendable>(within wait: Duration, _ work: @escaping @MainActor () async throws -> T) async throws -> T? {
        // task-owner: the login step; it runs to its end even when the run answers without it.
        let step = Task { try await work() } // inherits this type's main actor: the login step's own awaits leave it
        let (answers, continuation) = AsyncStream<Result<T, any Error>?>.makeStream(bufferingPolicy: .bufferingOldest(1))
        // task-owner: relays the step's answer; it ends with the step (a yield after finish is dropped).
        Task { continuation.yield(await step.result) }
        // task-owner: the deadline; cancelled below once an answer is in.
        let deadline = Task {
            // wakeup-allow: one-shot login deadline; cancelled when the step answers first
            try? await Task.sleep(for: wait)
            continuation.yield(nil)
        }
        defer { deadline.cancel(); continuation.finish() }
        for await answer in answers { return try answer?.get() }
        return nil
    }

    /// A relay chat refused before anything was sent.
    static func notSent(_ code: String, _ message: String) -> [String: ActionResultValue] {
        ["delivered": .bool(false), "ended": .bool(true), "error_code": .string(code), "error_message": .string(message)]
    }

    /// The answer's fields: what the CLI prints with `--json`. `linkLogin`: the link and login before the relay's request (cmuxterm-hq#7415's stage trace).
    static func relayFields(_ answer: CloudRelayChat.Answer, machineID: String, linkLogin: Duration? = nil) -> [String: ActionResultValue] {
        var fields: [String: ActionResultValue] = ["machine_id": .string(machineID), "reply": .string(answer.reply), "queued": .bool(answer.queued),
                                                   "ended": .bool(answer.ended), "delivered": .bool(answer.delivered)]
        let texts = ["session_id": answer.session, "prompt_id": answer.promptID, "stop_reason": answer.stopReason].merging(answer.errorTexts) { $1 } // and error_code, error_message, the machine's typed error
        for case let (key, text?) in texts { fields[key] = .string(text) }
        if let retryable = answer.errorRetryable { fields["error_retryable"] = .bool(retryable) }
        for case let (key, time?) in answer.stageTimes.merging(["link_login_ms": linkLogin]) { $1 } { fields[key] = .int(Int(time / .milliseconds(1))) }
        if let stages = answer.platformStages { fields["platform_stages_ms"] = .object(stages.mapValues { .int($0) }) }
        return fields
    }
}
