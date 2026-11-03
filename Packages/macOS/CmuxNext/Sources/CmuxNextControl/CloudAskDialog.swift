public import CmuxNextActions
public import CmuxNextSettings

/// An agent's Cloud start ask as the control surface shows it: a question dialog of `cmux agents
/// dialog list|answer` (and their MCP tools), and the `pending` answer of the agent's own
/// `cmux cloud start-session` that names it. Shapes only; who may answer is
/// cmux-cloud-start-core's `ask`, and the App holds the asks.
public enum CloudAskDialog {
    /// Every Cloud start ask's dialog id starts with this.
    public static let prefix = "cloud-start-"

    /// The command that answers `dialog` with `selection` (`start` or `notNow`).
    public static func command(_ dialog: String, _ selection: String) -> String {
        "cmux agents dialog answer \(dialog) --selection \(selection)"
    }

    /// One waiting ask as a question dialog, with the commands that answer it. Start is the
    /// person's unless they `delegated` it (an agent's answer is then taken too).
    public static func item(dialog: String, tab: String, text: String, caller: String?, machine: String, agent: String,
                            command asked: String, start: String, notNow: String, delegated: Bool) -> JSONValue {
        let options: [JSONValue] = [.object(["id": "start", "label": .string(start)]), .object(["id": "notNow", "label": .string(notNow)])]
        let session: JSONValue = caller.map(JSONValue.string) ?? .null
        return .object([
            "id": .string(dialog), "request_id": .string(dialog), "status": "pending", "source": "cmux",
            "kind": "question", "harness": "cmux", "ask": "cloudStartSession",
            "session_id": session, "agent_session": session, "session_name": .null, "tab_id": .string(tab),
            "title": .string(text), "machine": .string(machine), "agent": .string(agent), "command": .string(asked),
            "questions": .array([.object([
                "id": "cloudStartSession", "header": .null, "prompt": .string(text),
                "multi_select": false, "allows_other": false, "options": .array(options),
            ])]),
            "start_by": .string(delegated ? "person_or_agent" : "person"),
            "answer_commands": .object(["start": .string(command(dialog, "start")), "not_now": .string(command(dialog, "notNow"))]),
        ])
    }

    /// The agent session a dialog reply names as its caller; a Chief turn names the Home chat,
    /// not a session, and is an agent all the same. Nil for the person's own terminal.
    public static func callerSession(_ params: [String: JSONValue]) -> String? {
        let caller = params["caller"]?.objectValue
        return caller?["agent_session"]?.stringValue ?? (caller?["home_chat"]?.boolValue == true ? "home-chat" : nil)
    }

    /// A taken answer's reply.
    public static func answered(_ dialog: String, choice: String, start: Bool) -> JSONValue {
        .object(["request_id": .string(dialog), "status": .string(start ? "answered" : "denied"), "choice": .string(choice)])
    }

    /// An agent's run once its card asks: pending, waiting for the person, with the dialog that answers it.
    public static func pending(agent: String, dialog: String, text: String, machineID: String?, machineName: String?) -> [String: ActionResultValue] {
        var fields: [String: ActionResultValue] = ["pending": .bool(true), "agent": .string(agent), "waiting_for": .string("person"),
                                                   "dialog_id": .string(dialog), "answer_command": .string(command(dialog, "start")), "text": .string(text)]
        if let machineID { fields["machine_id"] = .string(machineID) }
        if let machineName { fields["machine_name"] = .string(machineName) }
        return fields
    }
}
