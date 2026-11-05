import CmuxNextActions
import CmuxNextCloud
import CmuxNextCloudUI
import Foundation

/// `cmux cloud relay-chat` (cmuxterm-hq#7086; Leo: "it should take <30 seconds from starting a thing to having a
/// response on cloud"): sends a prompt to an agent on a Cloud machine over the machine's relay (``CloudRelayChat``),
/// with no link from this Mac to the machine, and answers when the turn ends with the machine's acpmux session,
/// the reply and how long the first text took, or within ``CloudHandlers/answerWithin`` with what came so far
/// (``CloudRelayChat/answer(_:agent:prompt:cwd:promptID:within:)``). `delivered` false means the prompt certainly
/// never reached the machine. `cmux cloud start-chat` uses it first. A turn still running when this answers keeps
/// its stream until it ends; quitting the app closes it, which cancels that turn on the machine.
///
/// The person's own run only: an agent starts a Cloud chat with `cloud start-session`, which asks the person
/// first (``CloudStartSession``).
extension CloudStartSession {
    static func bindRelayChat(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        let cloud = context.services.cloud
        // action-wait-allow: the reply comes from the machine over the network; nothing local can stand in for it.
        CloudHandlers.bind("cloudRelayChat", registry, reason: reason) { invocation in
            // A refusal here sent nothing: it answers undelivered, so `cloud start-chat` goes the start-session way,
            // which asks an agent's person and words the same refusals.
            let machineID: String, started: Request, prompt: String
            do {
                guard !isAgent(invocation) else { throw ActionFailure(message: CloudStartSessionStrings.relayAgentRun) }
                machineID = try CloudHandlers.machine(invocation, context).machineID
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
            let promptID = (invocation["promptId"]?.stringValue?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            // A person's run waits for the whole turn and shows the reply, or why there is none.
            guard CloudHandlers.origin(of: invocation) != .user else {
                return CloudHandlers.runTracked("cloud relay chat", context) {
                    guard let relay = cloud.relayChat else { throw ActionFailure(message: CloudStartSessionStrings.relayUnavailable) }
                    let answer = try await relay.chat(machineID, agent: started.agent, prompt: prompt, cwd: started.cwd, promptID: promptID)
                    let text = answer.errorMessage.map { answer.reply.isEmpty ? $0 : answer.reply + "\n\n" + $0 } ?? answer.reply
                    CloudPresenter.show(CloudStartSessionStrings.relayReplyTitle, text, copyable: true, in: CloudHandlers.window(context))
                }
            }
            CloudHandlers.result("cloud relay chat", context) {
                guard let relay = cloud.relayChat else { return notSent("cloud.relay.unavailable", CloudStartSessionStrings.relayUnavailable) }
                let answer = try await relay.answer(machineID, agent: started.agent, prompt: prompt, cwd: started.cwd,
                                                    promptID: promptID, within: CloudHandlers.answerWithin)
                return relayFields(answer, machineID: machineID)
            }
        }
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
