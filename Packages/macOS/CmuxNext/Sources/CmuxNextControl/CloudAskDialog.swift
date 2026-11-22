public import CmuxNextActions
public import CmuxNextSettings

/// One agent's Cloud start ask as the control surface shows it: a question dialog of `cmux agents
/// dialog list|answer` (and their MCP tools), and the `pending` answer of the agent's own
/// `cmux cloud start-session` that names it. Shapes only; who may answer is
/// cmux-cloud-start-core's `ask`, and the App holds the asks.
public struct CloudAskDialog: Sendable, Equatable {
    /// Every Cloud start ask's dialog id starts with this.
    public static let prefix = "cloud-start-"

    /// The dialog id (``prefix`` and the ask's token).
    public let id: String

    public init(id: String) { self.id = id }

    /// Whether `id` names a Cloud start ask.
    public static func owns(_ id: String) -> Bool { id.hasPrefix(prefix) }

    /// The command that answers it with `selection` (`start` or `notNow`).
    public func command(_ selection: String) -> String {
        "cmux agents dialog answer \(id) --selection \(selection)"
    }

    /// The waiting ask as a question dialog, with the commands that answer it. Start is the
    /// person's unless they `delegated` it (an agent's answer is then taken too).
    public func item(tab: String, text: String, caller: String?, machine: String, agent: String,
                     command asked: String, start: String, notNow: String, delegated: Bool) -> JSONValue {
        let options: [JSONValue] = [.object(["id": "start", "label": .string(start)]), .object(["id": "notNow", "label": .string(notNow)])]
        let session: JSONValue = caller.map(JSONValue.string) ?? .null
        return .object([
            "id": .string(id), "request_id": .string(id), "status": "pending", "source": "cmux",
            "kind": "question", "harness": "cmux", "ask": "cloudStartSession",
            "session_id": session, "agent_session": session, "session_name": .null, "tab_id": .string(tab),
            "title": .string(text), "machine": .string(machine), "agent": .string(agent), "command": .string(asked),
            "questions": .array([.object([
                "id": "cloudStartSession", "header": .null, "prompt": .string(text),
                "multi_select": false, "allows_other": false, "options": .array(options),
            ])]),
            "start_by": .string(delegated ? "person_or_agent" : "person"),
            "answer_commands": .object(["start": .string(command("start")), "not_now": .string(command("notNow"))]),
        ])
    }

    /// The selection as an option id: a listed label (`start` and `notNow` as shown in any
    /// language) maps to its id, anything else goes on as given.
    public func selection(_ selection: String, start: String, notNow: String) -> String {
        let word = selection.trimmingCharacters(in: .whitespaces)
        if word.caseInsensitiveCompare(start) == .orderedSame { return "start" }
        if word.caseInsensitiveCompare(notNow) == .orderedSame { return "notNow" }
        return word
    }

    /// A reply to the ask once cmux-cloud-start-core ruled on it: `choice` (`start` or `notNow`; nil
    /// when the selection named neither) and whether the caller may give it (`allowed`). Refusals in
    /// order: `invalid_params` (unknown choice), `person_required` (not the caller's), `not_found`
    /// (`take` found the ask gone); else the ask is answered (`take(start)`) and its reply returned.
    public func reply(choice: String?, allowed: Bool, take: (_ start: Bool) -> Bool,
                      unknown: String, personRequired: String, gone: String) throws -> JSONValue {
        let request: JSONValue = ["request_id": .string(id)]
        guard let choice else { throw ControlError.invalidParams(unknown, data: request) }
        guard allowed else { throw ControlError(code: "person_required", message: personRequired, data: request) }
        guard take(choice == "start") else { throw ControlError(code: "not_found", message: gone, data: request) }
        return answered(choice: choice, start: choice == "start")
    }

    /// A taken answer's reply.
    public func answered(choice: String, start: Bool) -> JSONValue {
        .object(["request_id": .string(id), "status": .string(start ? "answered" : "denied"), "choice": .string(choice)])
    }

    /// The agent's run once its card asks: pending, waiting for the person, with this dialog.
    public func pending(agent: String, text: String, machineID: String?, machineName: String?) -> [String: ActionResultValue] {
        var fields: [String: ActionResultValue] = ["pending": .bool(true), "agent": .string(agent), "waiting_for": .string("person"),
                                                   "dialog_id": .string(id), "answer_command": .string(command("start")), "text": .string(text)]
        if let machineID { fields["machine_id"] = .string(machineID) }
        if let machineName { fields["machine_name"] = .string(machineName) }
        return fields
    }
}

extension [String: JSONValue] {
    /// The agent session a dialog reply names as its caller; a Chief turn names the Home chat,
    /// not a session, and is an agent all the same. Nil for the person's own terminal.
    public var cloudAskCallerSession: String? {
        let caller = self["caller"]?.objectValue
        return caller?["agent_session"]?.stringValue ?? (caller?["home_chat"]?.boolValue == true ? "home-chat" : nil)
    }
}
