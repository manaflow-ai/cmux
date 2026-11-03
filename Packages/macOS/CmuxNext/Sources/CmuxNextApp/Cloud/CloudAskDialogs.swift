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

    func owns(_ id: String) -> Bool { id.hasPrefix(CloudAskDialog.prefix) }

    func items() -> [JSONValue] {
        let delegated = delegated()
        return (asks()?.waiting ?? []).map { Self.item($0, delegated: delegated) }
    }

    static func item(_ ask: CloudStartSessionAsks.Waiting, delegated: Bool) -> JSONValue {
        CloudAskDialog.item(dialog: ask.dialog, tab: ask.tab, text: ask.text, caller: ask.caller, machine: ask.asked.machine, agent: ask.asked.agent,
                            command: ask.asked.command, start: CloudStartSessionStrings.start, notNow: CloudMoveAskStrings.notNow, delegated: delegated)
    }

    func reply(_ id: String, selection: String, params: [String: JSONValue]) throws -> JSONValue {
        guard let asks = asks(), asks.waiting.contains(where: { $0.dialog == id }) else {
            throw ControlError(code: "not_found", message: CloudStartSessionStrings.dialogGone(id), data: ["request_id": .string(id)])
        }
        let answer = CloudStartCore().askAnswer(origin: params["origin"]?.stringValue, agentSession: CloudAskDialog.callerSession(params),
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
        return CloudAskDialog.answered(id, choice: choice.rawValue, start: choice == .start)
    }
}
