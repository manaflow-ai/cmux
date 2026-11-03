import CmuxNextCloud
import CmuxNextControl
import CmuxNextSettings
import Foundation

/// An agent's Cloud start asks (``CloudStartSessionAsks``) as dialogs of `cmux agents dialog
/// list|answer` and their MCP tools (``AgentDialogDesk``), so an agent's caller sees what its run
/// waits on and the person can answer it from their own terminal.
///
/// Who may answer is cmux-cloud-start-core's `ask` (``CloudStartCore/askAnswer(origin:agentSession:delegated:selection:)``):
/// Not now is anyone's; Start is the person's (a CLI request that names no agent session), or an
/// agent's when the person turned on `cloud.agentsStartWithoutAsking` (``CloudAgentStartSetting``),
/// which agents cannot set. Nothing here answers on its own.
@MainActor
final class CloudAskDialogs: AgentDialogAppAsks {
    private let asks: () -> CloudStartSessionAsks?
    private let delegated: () -> Bool

    init(asks: @escaping () -> CloudStartSessionAsks?, delegated: @escaping () -> Bool) {
        self.asks = asks
        self.delegated = delegated
    }

    convenience init(services: AppServices) {
        self.init(asks: { [weak services] in services?.cloud.startSessionAsks }, delegated: { [weak services] in
            CloudAgentStartSetting().delegated(in: services?.settings?.snapshot.root ?? .object([:]))
        })
    }

    func owns(_ id: String) -> Bool { id.hasPrefix("cloud-start-") }

    func items() -> [JSONValue] {
        let delegated = delegated()
        return (asks()?.waiting ?? []).map { Self.item($0, delegated: delegated) }
    }

    /// One waiting ask as a question dialog, with the commands that answer it.
    static func item(_ ask: CloudStartSessionAsks.Waiting, delegated: Bool) -> JSONValue {
        let options: [JSONValue] = [
            .object(["id": "start", "label": .string(CloudStartSessionStrings.start)]),
            .object(["id": "notNow", "label": .string(CloudMoveAskStrings.notNow)]),
        ]
        let session: JSONValue = ask.caller.map(JSONValue.string) ?? .null
        return .object([
            "id": .string(ask.dialog), "request_id": .string(ask.dialog), "status": "pending", "source": "cmux",
            "kind": "question", "harness": "cmux", "ask": "cloudStartSession",
            "session_id": session, "agent_session": session, "session_name": .null, "tab_id": .string(ask.tab),
            "title": .string(ask.text), "machine": .string(ask.asked.machine), "agent": .string(ask.asked.agent),
            "command": .string(ask.asked.command),
            "questions": .array([.object([
                "id": "cloudStartSession", "header": .null, "prompt": .string(ask.text),
                "multi_select": false, "allows_other": false, "options": .array(options),
            ])]),
            // Start is the person's unless they delegated it (an agent's answer is then taken too).
            "start_by": .string(delegated ? "person_or_agent" : "person"),
            "answer_commands": .object([
                "start": .string("cmux agents dialog answer \(ask.dialog) --selection start"),
                "not_now": .string("cmux agents dialog answer \(ask.dialog) --selection notNow"),
            ]),
        ])
    }

    func reply(_ id: String, selection: String, params: [String: JSONValue]) throws -> JSONValue {
        guard let asks = asks(), asks.waiting.contains(where: { $0.dialog == id }) else {
            throw ControlError(code: "not_found", message: CloudStartSessionStrings.dialogGone(id), data: ["request_id": .string(id)])
        }
        let caller = params["caller"]?.objectValue
        // A Chief turn names the Home chat, not its session: it is an agent all the same.
        let session = caller?["agent_session"]?.stringValue ?? (caller?["home_chat"]?.boolValue == true ? "home-chat" : nil)
        let answer = CloudStartCore().askAnswer(origin: params["origin"]?.stringValue, agentSession: session,
                                                delegated: delegated(), selection: selection)
        guard let choice = answer.choice else {
            throw ControlError.invalidParams(CloudStartSessionStrings.unknownChoice(id), data: ["request_id": .string(id)])
        }
        guard answer.allowed else {
            throw ControlError(code: "person_required", message: CloudStartSessionStrings.personRequired(id), data: ["request_id": .string(id)])
        }
        guard asks.answer(dialog: id, start: choice == .start) else {
            throw ControlError(code: "not_found", message: CloudStartSessionStrings.dialogGone(id), data: ["request_id": .string(id)])
        }
        return .object(["request_id": .string(id), "status": .string(choice == .start ? "answered" : "denied"),
                        "choice": .string(choice.rawValue)])
    }
}
