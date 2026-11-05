import CmuxNextActions
import CmuxNextCloud
import CmuxNextCloudCredentials
import Foundation

/// `cmux cloud relay-chat` (cmuxterm-hq#7086; Leo: "it should take <30 seconds from starting a thing to having a
/// response on cloud"): sends a prompt to an agent on a Cloud machine over the machine's relay (``CloudRelayChat``),
/// with no link from this Mac to the machine, and answers when the turn ends with the machine's acpmux session,
/// the reply and how long the first text took, or within ``CloudHandlers/answerWithin`` with what came so far
/// (``CloudRelayChat/answer(_:agent:prompt:cwd:promptID:within:)``). `delivered` false means the prompt certainly
/// never reached the machine. `cmux cloud start-chat` uses it first. A turn still running when this answers keeps
/// its stream until it ends; quitting the app closes it, which cancels that turn on the machine.
///
/// Before the send the machine takes the person's harness login, as `cloud start-session`'s start does
/// (``passHarnessLogin(_:agent:login:still:)``; Leo: "we have the daemon, we have the token, we have the thing that
/// can just send it over the authentication"). A chat sent without it answered "Claude is not signed in here". A
/// login the rules refuse, or one the machine still lacks after the step, sends nothing (``relayLoginRefusal(_:_:machine:)``).
///
/// The person's own run only: an agent starts a Cloud chat with `cloud start-session`, which asks the person
/// first (``CloudStartSession``).
extension CloudStartSession {
    /// The relay chat's two steps on the network: the machine's harness login, then the relay itself. Tests stand in for both.
    struct RelaySteps {
        /// Runs ``passHarnessLogin(_:agent:login:still:)`` on the machine; it leaves its decision on `harnessLogin`.
        var login: @MainActor (CloudMachineSession, Request, _ still: () throws -> Void) async throws -> Void
        var relay: @MainActor () -> CloudRelayChat?
        /// How long a CLI or MCP run waits for `login` before it answers without sending.
        var loginWithin: Duration = CloudStartSession.loginWithin

        static func live(_ services: AppServices) -> RelaySteps {
            RelaySteps(login: { try await CloudStartSession(services: services).passHarnessLogin($0, agent: $1.agent, login: $1.login, still: $2) }, relay: { services.cloud.relayChat })
        }
    }

    static func bindRelayChat(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?,
                              steps: RelaySteps? = nil) {
        let cloud = context.services.cloud, steps = steps ?? .live(context.services)
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
            let machineID = machine.machineID, account = cloud.account
            let promptID = (invocation["promptId"]?.stringValue?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            // The machine takes the login first; the account that asked is checked after its wait, as start-session's is.
            let login: @MainActor () async throws -> (code: String, message: String)? = {
                try await steps.login(machine, started) { try Self.checked(account, now: cloud.account, started.asked(machine: machine.machine.title)) }
                let refusal = relayLoginRefusal(machine.harnessLogin, started, machine: machine.machine.title)
                // The verdict only: no token, path or provider output.
                cloud.logger.info("cloud relay chat: harness login \(refusal?.code ?? "ready", privacy: .public) before the send to \(machineID, privacy: .public)")
                return refusal
            }
            // A person's run waits for the whole turn and shows the reply, or why there is none.
            guard CloudHandlers.origin(of: invocation) != .user else {
                return CloudHandlers.runTracked("cloud relay chat", context) {
                    guard let relay = steps.relay() else { throw ActionFailure(message: CloudStartSessionStrings.relayUnavailable) }
                    if let refusal = try await login() { throw ActionFailure(message: refusal.message) }
                    let answer = try await relay.chat(machineID, agent: started.agent, prompt: prompt, cwd: started.cwd, promptID: promptID)
                    let text = answer.errorMessage.map { answer.reply.isEmpty ? $0 : answer.reply + "\n\n" + $0 } ?? answer.reply
                    CloudPresenter.show(CloudStartSessionStrings.relayReplyTitle, text, copyable: true, in: CloudHandlers.window(context))
                }
            }
            CloudHandlers.result("cloud relay chat", context) {
                guard let relay = steps.relay() else { return notSent("cloud.relay.unavailable", CloudStartSessionStrings.relayUnavailable) }
                // The run answers within the action's result deadline: the login step gets `loginWithin` of it and the turn
                // the rest. A step still running sends nothing (it goes on and ends on its own); the caller goes the
                // start-session way, whose start waits for its own step.
                let clock = ContinuousClock(), begun = clock.now
                let decided: (code: String, message: String)??
                do { decided = try await Self.first(within: steps.loginWithin, login) } catch let failure as ActionFailure { return notSent("cloud.relay.refused", failure.message) }
                guard let refusal = decided else {
                    return notSent("cloud.relay.login_pending", CloudStartSessionStrings.relayLoginPending(started.asked(machine: machine.machine.title)))
                }
                if let refusal {
                    // The rules' reason, and the start-session command that recovers (its `--login` choice is the caller's).
                    var fields = notSent(refusal.code, refusal.message)
                    fields["command"] = .string(started.asked(machine: machine.machine.title).command)
                    if let reason = machine.harnessLogin?.reason { fields["login_reason"] = .string(reason.rawValue) }
                    return fields
                }
                let answer = try await relay.answer(machineID, agent: started.agent, prompt: prompt, cwd: started.cwd,
                                                    promptID: promptID, within: CloudHandlers.answerWithin - (clock.now - begun))
                return relayFields(answer, machineID: machineID)
            }
        }
    }

    /// Why the relay sends nothing after the machine's login step (`decision`, nil when none ran): the rules refused
    /// it (a run that may not ask, as start-session refuses), or Claude there still has no login (this Mac holds none
    /// of the person's to give it), or the copy failed. Nil sends. Every field is fixed text: no token or provider output.
    static func relayLoginRefusal(_ decision: CloudHarnessLoginDecision?, _ started: Request, machine: String) -> (code: String, message: String)? {
        guard let decision else { return nil }
        let asked = started.asked(machine: machine)
        if let reason = decision.refusal { return ("cloud.relay.login_refused", CloudStartSessionStrings.loginRefused(reason, asked)) }
        // No login copied to a machine that needs one: none cached on this Mac, or the person said no to the copy of the
        // one it holds (the confirm, or Release's one-time consent: both come only after the cache check).
        if decision.outcome == CloudStartChat.loginDeclined { return ("cloud.relay.login_declined", CloudStartSessionStrings.relayLoginDeclined(asked)) }
        if CloudStartChat.signInOnMachine.contains(decision.outcome) { return ("cloud.relay.login_missing", CloudStartSessionStrings.relayLoginMissing(asked)) }
        if let outcome = decision.outcome, outcome.hasPrefix(CloudStartChat.loginFailed) {
            return ("cloud.relay.login_failed", CloudStartSessionStrings.relayLoginFailed(asked, reason: Self.reason(String(outcome.dropFirst(CloudStartChat.loginFailed.count)))))
        }
        return nil
    }

    /// How long a CLI or MCP relay chat waits for the login step: well inside ``CloudHandlers/answerWithin``, so the turn keeps 20 s.
    static let loginWithin: Duration = .seconds(15)

    /// `work`'s answer if it comes within `wait`, else nil (the work goes on to its end). Its error is thrown.
    static func first<T: Sendable>(within wait: Duration, _ work: @escaping @MainActor () async throws -> T) async throws -> T? {
        // task-owner: the login step; it runs to its end even when the run answers without it.
        let step = Task { @MainActor in try await work() }
        let (answers, continuation) = AsyncStream<Result<T, any Error>?>.makeStream(bufferingPolicy: .bufferingOldest(1))
        // task-owner: relays the step's answer; it ends with the step (a yield after finish is dropped).
        Task { continuation.yield(await step.result) }
        // task-owner: the deadline; cancelled below once an answer is in.
        let deadline = Task {
            // wakeup-allow: one-shot login deadline; cancelled when the step answers first
            try? await Task.sleep(for: wait)
            continuation.yield(nil)
        }
        defer {
            deadline.cancel()
            continuation.finish()
        }
        for await answer in answers { return try answer?.get() }
        return nil
    }

    /// A relay chat refused before anything was sent.
    static func notSent(_ code: String, _ message: String) -> [String: ActionResultValue] {
        ["delivered": .bool(false), "ended": .bool(true), "error_code": .string(code), "error_message": .string(message)]
    }

    /// The answer's fields: what the CLI prints with `--json`.
    static func relayFields(_ answer: CloudRelayChat.Answer, machineID: String) -> [String: ActionResultValue] {
        var fields: [String: ActionResultValue] = ["machine_id": .string(machineID), "reply": .string(answer.reply),
                                                   "queued": .bool(answer.queued), "ended": .bool(answer.ended),
                                                   "delivered": .bool(answer.delivered)]
        let texts = ["session_id": answer.session, "prompt_id": answer.promptID, "stop_reason": answer.stopReason,
                     "error_code": answer.errorCode, "error_message": answer.errorMessage]
        for case let (key, text?) in texts { fields[key] = .string(text) }
        if let first = answer.firstText { fields["first_text_ms"] = .int(Int(first / .milliseconds(1))) }
        if let total = answer.total { fields["total_ms"] = .int(Int(total / .milliseconds(1))) }
        return fields
    }
}
