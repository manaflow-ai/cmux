import CmuxAgentQuestion
import CmuxNextAgentPane
import CmuxNextControl
import CmuxNextSettings
import Foundation

/// The permission and question dialogs agents wait on in this app's acpmux, for the control
/// socket (`feed.list`, `feed.permission.reply`, `feed.question.reply`): `cmux agents dialog
/// list|answer`, `cmux agents wait --until dialog`, `cmux agents events` and their MCP tools.
///
/// - A list reads every session's pending prompts (`_acpmux/sessions`, then `_acpmux/info` for
///   each session with one). No acpmux: no dialogs.
/// - A permission is only denied here (its reject option, else a cancel). An allow is the
///   person's own (acpmux `hub/person.rs`): the caller is a script or another agent, and this
///   app's connection is the person, so an allow is refused before acpmux sees it.
/// - A question (Claude Code, Codex, the Chief) is answered in the asking harness's shape
///   (``AgentQuestion/reply(_:)``). A prompt whose choices are permission options (an
///   interactive ACP prompt) is a permission here: it is only denied.
/// - What this desk answered stays listed with `pending_only: false` for this launch only.
@MainActor
final class AgentDialogDesk {
    typealias Opener = @MainActor () async -> (any AgentDialogLine)?

    /// The most answered dialogs kept for `pending_only: false`.
    static let answeredLimit = 50

    private let open: Opener
    /// The tab id of the chat that shows an acpmux session, when this app shows it.
    private let tab: @MainActor (String) -> String?
    private var answered: [JSONValue] = []

    init(open: @escaping Opener, tab: @escaping @MainActor (String) -> String? = { _ in nil }) {
        self.open = open
        self.tab = tab
    }

    /// One pending prompt as acpmux reports it.
    struct Pending {
        let session: String
        let sessionName: String?
        let permission: String
        let request: [String: Any]

        /// The prompt as a question this socket may answer; nil for a tool permission.
        var question: AgentQuestion? {
            guard let data = try? JSONSerialization.data(withJSONObject: request),
                  let json = try? AgentQuestionJSON(data: data),
                  let question = AgentQuestion(permissionRequest: json, permissionId: permission, session: session),
                  question.source.harness != .acp else { return nil }
            return question
        }
    }

    // MARK: feed.list

    /// `{items}`: the pending dialogs, then (with `pendingOnly` false) those this desk answered.
    func list(pendingOnly: Bool) async -> JSONValue {
        var items: [JSONValue] = []
        if let line = await open() {
            defer { line.close() }
            items = await pending(on: line).map { item($0) }
        }
        if !pendingOnly { items += answered.reversed() }
        return .object(["items": .array(items)])
    }

    private func pending(on line: any AgentDialogLine) async -> [Pending] {
        // Page the list until a server-side pending-permission filter is
        // available. Status alone does not guarantee whether prompts remain.
        var sessions: [[String: Any]] = []
        var cursor: String?
        var seen: Set<String> = []
        var seenSessions: Set<String> = []
        while true { // wakeup-allow: each pass awaits a daemon page; a terminal page, malformed reply, or repeated cursor ends it
            var params: [String: Any] = ["limit": 64]
            if let cursor { params["cursor"] = cursor }
            guard let page = await line.call("_acpmux/sessions", params) else { return [] }
            guard let pageRows = page["sessions"] as? [[String: Any]] else { return [] }
            for row in pageRows {
                guard let id = row["sessionId"] as? String, !id.isEmpty else { continue }
                let peer = row["peer"] as? String ?? ""
                let key = "\(peer)/\(id)"
                if seenSessions.insert(key).inserted { sessions.append(row) }
            }
            guard let next = (page["nextCursor"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { break }
            guard seen.insert(next).inserted else { return [] }
            cursor = next
        }
        var out: [Pending] = []
        for summary in sessions where (summary["pendingPermissions"] as? NSNumber)?.intValue ?? 0 > 0 {
            guard let session = summary["sessionId"] as? String else { continue }
            let entries = (await line.call("_acpmux/info", ["sessionId": session]))?["pending"] as? [[String: Any]] ?? []
            for entry in entries {
                guard let permission = entry["permissionId"] as? String, let request = entry["request"] as? [String: Any] else { continue }
                out.append(Pending(session: session, sessionName: summary["name"] as? String, permission: permission, request: request))
            }
        }
        return out
    }

    private func item(_ prompt: Pending, status: String = "pending") -> JSONValue {
        let call = prompt.request["toolCall"] as? [String: Any] ?? [:]
        let title = (call["title"] as? String ?? "").secretsScrubbed.acpmuxVisible.acpmuxCut(500)
        var item: [String: JSONValue] = [
            "id": .string(prompt.permission), "request_id": .string(prompt.permission), "status": .string(status),
            "source": "acpmux", "session_id": .string(prompt.session), "agent_session": .string(prompt.session),
            "title": .string(title), "session_name": .orNull(prompt.sessionName), "tab_id": .orNull(tab(prompt.session)),
        ]
        if let question = prompt.question {
            item["kind"] = "question"
            item["harness"] = .string(question.source.harness.rawValue)
            item["questions"] = .array(question.items.map { entry in
                .object([
                    "id": .string(entry.id), "header": .orNull(entry.header), "prompt": .string(entry.prompt),
                    "multi_select": .bool(entry.multiSelect), "allows_other": .bool(entry.allowsOther),
                    "options": .array(entry.options.map { .object(["id": .string($0.id), "label": .string($0.label)]) }),
                ])
            })
        } else {
            item["kind"] = "permissionRequest"
            if let kind = call["kind"] as? String { item["tool"] = .string(kind.acpmuxVisible.acpmuxCut(200)) }
            let input = call["rawInput"] as? [String: Any] ?? [:]
            if let command = input.acpmuxShownCommand { item["command"] = .string(command.secretsScrubbed.acpmuxVisible.acpmuxCut(8000)) }
            item["options"] = .array((prompt.request["options"] as? [[String: Any]] ?? []).map { option in
                .object(["id": .orNull(option["optionId"] as? String), "kind": .orNull(option["kind"] as? String),
                         "name": .orNull(option["name"] as? String)])
            })
        }
        return .object(item)
    }

    // MARK: feed.permission.reply

    /// Denies a pending permission (or declines a question): `{request_id, mode: "deny"}`.
    func replyPermission(_ params: [String: JSONValue]) async throws -> JSONValue {
        let id = try requestID(params)
        let mode = params["mode"]?.stringValue ?? ""
        guard mode == "deny" else {
            throw ControlError(code: "person_required", message: Self.text("agentDialogs.allowRefused",
                "Only a deny can be sent here; a person approves permissions in cmux"), data: ["request_id": .string(id)])
        }
        let (line, prompt) = try await find(id)
        defer { line.close() }
        var reply: [String: Any] = ["sessionId": prompt.session, "permissionId": prompt.permission]
        if let question = prompt.question {
            if let option = question.declineReply()?.optionId { reply["optionId"] = option }
        } else if let option = (prompt.request["options"] as? [[String: Any]] ?? []).acpmuxOption(allow: false) {
            reply["optionId"] = option
        }
        try await respond(line, reply, id: id)
        remember(prompt, status: "denied")
        return .object(["request_id": .string(id), "status": "denied"])
    }

    // MARK: feed.question.reply

    /// Answers a pending question: `{request_id, selections}`. A selection is an option's label or
    /// id (or Other text where the item takes it) for a one-item question, else `ITEM=CHOICE`,
    /// where ITEM is the item's id, prompt or header.
    func replyQuestion(_ params: [String: JSONValue]) async throws -> JSONValue {
        let id = try requestID(params)
        let selections = params["selections"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard !selections.isEmpty else {
            throw ControlError.invalidParams(Self.text("agentDialogs.noSelections", "feed.question.reply needs `selections`"))
        }
        let (line, prompt) = try await find(id)
        defer { line.close() }
        guard let question = prompt.question else {
            throw ControlError.invalidParams(Self.text("agentDialogs.notQuestion",
                "This dialog is a permission, not a question; it can only be denied"), data: ["request_id": .string(id)])
        }
        let answer = try Self.answer(selections, to: question)
        let built: AgentQuestionReply
        do { built = try question.reply(answer) } catch {
            throw ControlError.invalidParams(Self.text("agentDialogs.badAnswer", "The answer does not fit the question: %@",
                String(describing: error)), data: ["request_id": .string(id)])
        }
        guard line.isPerson else {
            throw ControlError(code: "person_required", message: Self.text("agentDialogs.notPerson",
                "acpmux did not take this app's person proof; answer the question in cmux"), data: ["request_id": .string(id)])
        }
        guard let data = try? built.params.data(), let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ControlError(code: "internal", message: Self.text("agentDialogs.encodeFailed", "The answer could not be encoded"))
        }
        try await respond(line, reply, id: id)
        remember(prompt, status: "answered")
        return .object(["request_id": .string(id), "status": "answered"])
    }

    /// The selections as an answer: each one names an item (`ITEM=CHOICE`, or the only item) and
    /// an option of it by id or label, exact first, then ignoring case; other text is the item's
    /// Other text where it takes one.
    static func answer(_ selections: [String], to question: AgentQuestion) throws -> AgentQuestionAnswer {
        var chosen: [String: AgentQuestionAnswer.Selection] = [:]
        for selection in selections {
            let (item, value) = try target(selection, in: question)
            var current = chosen[item.id] ?? .init()
            let match = item.options.first { $0.id == value || $0.label == value }
                ?? item.options.first { $0.id.caseInsensitiveCompare(value) == .orderedSame || $0.label.caseInsensitiveCompare(value) == .orderedSame }
            if let match {
                if !current.optionIDs.contains(match.id) { current.optionIDs.append(match.id) }
            } else if item.allowsOther {
                current = .init(optionIDs: current.optionIDs, other: [current.other, value].compactMap { $0 }.joined(separator: ", "))
            } else {
                throw ControlError.invalidParams(text("agentDialogs.unknownOption", "%1$@ is not an option of %2$@; choose from: %3$@",
                    value, item.header ?? item.prompt, item.options.map(\.label).joined(separator: ", ")))
            }
            chosen[item.id] = current
        }
        return AgentQuestionAnswer(selections: chosen)
    }

    private static func target(_ selection: String, in question: AgentQuestion) throws -> (AgentQuestion.Item, String) {
        for split in selection.indices where selection[split] == "=" {
            let key = selection[..<split].trimmingCharacters(in: .whitespaces)
            let names = { (item: AgentQuestion.Item) in [item.id, item.prompt, item.header ?? ""] }
            let item = question.items.first { names($0).contains(key) }
                ?? question.items.first { names($0).contains { !$0.isEmpty && $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame } }
            if let item { return (item, selection[selection.index(after: split)...].trimmingCharacters(in: .whitespaces)) }
        }
        guard question.items.count == 1 else {
            throw ControlError.invalidParams(text("agentDialogs.nameTheItem",
                "This question has several items; give each selection as ITEM=CHOICE (the item's id, prompt or header)"))
        }
        return (question.items[0], selection.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Shared

    private func requestID(_ params: [String: JSONValue]) throws -> String {
        guard let id = params["request_id"]?.stringValue, !id.isEmpty else {
            throw ControlError.invalidParams(Self.text("agentDialogs.noRequest", "The reply needs `request_id`"))
        }
        return id
    }

    /// A connection and the pending prompt `id` names on it; the caller closes the connection.
    private func find(_ id: String) async throws -> (any AgentDialogLine, Pending) {
        guard let line = await open() else {
            throw ControlError(code: "unavailable", message: Self.text("agentDialogs.noAcpmux", "No agent daemon (acpmux) answers in this app"))
        }
        guard let prompt = await pending(on: line).first(where: { $0.permission == id }) else {
            line.close()
            throw ControlError(code: "not_found", message: Self.text("agentDialogs.notFound",
                "No pending dialog %@; it may have been answered or ended", id), data: ["request_id": .string(id)])
        }
        return (line, prompt)
    }

    private func respond(_ line: any AgentDialogLine, _ params: [String: Any], id: String) async throws {
        guard await line.call("_acpmux/permission_respond", params) != nil else {
            throw ControlError(code: "acpmux.refused", message: Self.text("agentDialogs.refused",
                "The agent daemon refused the reply to %@", id), data: ["request_id": .string(id)])
        }
    }

    private func remember(_ prompt: Pending, status: String) {
        answered.append(item(prompt, status: status))
        if answered.count > Self.answeredLimit { answered.removeFirst(answered.count - Self.answeredLimit) }
    }

    private static func text(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "AgentDialogs", bundle: .module)
    }

    private static func text(_ key: StaticString, _ english: String.LocalizationValue, _ arguments: any CVarArg...) -> String {
        String(format: String(localized: key, defaultValue: english, table: "AgentDialogs", bundle: .module), arguments: arguments)
    }
}

private extension JSONValue {
    /// The text, or null.
    static func orNull(_ text: String?) -> JSONValue { text.map(JSONValue.string) ?? .null }
}
