import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextControl
import CmuxNextSettings
import Foundation

/// An agent's Cloud start asks (``CloudStartSessionAsks``) as `cmux agents dialog` dialogs
/// (``AgentDialogDesk``, shapes in ``CloudAskDialog``). Who may answer is cmux-cloud-start-core's `ask` (``CloudStartCore/askAnswer(origin:agentSession:delegated:selection:)``):
/// Not now is anyone's; Start is the person's (a CLI request that names no agent session), or an
/// agent's when the person turned on `cloud.agentsStartWithoutAsking` (``CloudAgentStartSetting``),
/// which agents cannot set. Nothing here answers on its own.
@MainActor
final class CloudAskDialogs: AgentDialogAppAsks {
    private let asks: () -> CloudStartSessionAsks?
    private let delegated: () -> Bool

    init(asks: @escaping () -> CloudStartSessionAsks?, delegated: @escaping () -> Bool) {
        (self.asks, self.delegated) = (asks, delegated)
    }

    convenience init(services: AppServices) {
        self.init(asks: { [weak services] in services?.cloud.startSessionAsks }, delegated: { [weak services] in
            CloudAgentStartSetting().delegated(in: services?.settings?.snapshot.root ?? .object([:]))
        })
    }

    func owns(_ id: String) -> Bool { CloudAskDialog.owns(id) }

    func items() -> [JSONValue] {
        let delegated = delegated()
        return (asks()?.waiting ?? []).map { Self.item($0, delegated: delegated) }
    }

    static func item(_ ask: CloudStartSessionAsks.Waiting, delegated: Bool) -> JSONValue {
        CloudAskDialog(id: ask.dialog).item(tab: ask.tab, text: ask.text, caller: ask.caller, machine: ask.asked.machine, agent: ask.asked.agent,
                                            command: ask.asked.command, start: CloudStartSessionStrings.start, notNow: CloudMoveAskStrings.notNow, delegated: delegated)
    }

    func reply(_ id: String, selection: String, params: [String: JSONValue]) throws -> JSONValue {
        guard let asks = asks(), asks.waiting.contains(where: { $0.dialog == id }) else {
            throw ControlError(code: "not_found", message: CloudStartSessionStrings.dialogGone(id), data: ["request_id": .string(id)])
        }
        let dialog = CloudAskDialog(id: id)
        // A listed label (in the app's language) is its option: the rules read only the ids.
        let picked = dialog.selection(selection, start: CloudStartSessionStrings.start, notNow: CloudMoveAskStrings.notNow)
        let answer = CloudStartCore().askAnswer(origin: params["origin"]?.stringValue, agentSession: params.cloudAskCallerSession,
                                                delegated: delegated(), selection: picked)
        return try dialog.reply(choice: answer.choice?.rawValue, allowed: answer.allowed, take: { asks.answer(dialog: id, start: $0) },
                                unknown: CloudStartSessionStrings.unknownChoice(id), personRequired: CloudStartSessionStrings.personRequired(id),
                                gone: CloudStartSessionStrings.dialogGone(id))
    }
}
