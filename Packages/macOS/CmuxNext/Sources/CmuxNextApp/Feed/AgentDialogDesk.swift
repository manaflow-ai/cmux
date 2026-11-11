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
/// - The app's own asks (an agent's Cloud start card, ``AgentDialogAppAsks``) are listed after
///   acpmux's, and their answers go to them, which decide who may give each.
@MainActor
final class AgentDialogDesk {
    typealias Opener = @MainActor () async -> (any AgentDialogLine)?

    /// The most answered dialogs kept for `pending_only: false`.
    static let answeredLimit = 50

    private let open: Opener
    /// The tab id of the chat that shows an acpmux session, when this app shows it.
    private let tab: @MainActor (String) -> String?
    private var answered: [JSONValue] = []
    /// The app's own asks, listed and answered beside acpmux's prompts.
    private let asks: (any AgentDialogAppAsks)?

    init(open: @escaping Opener, tab: @escaping @MainActor (String) -> String? = { _ in nil }, asks: (any AgentDialogAppAsks)? = nil) {
        self.open = open
        self.tab = tab
        self.asks = asks
    }

    /// One pending prompt as acpmux reports it.
    typealias Pending = AgentDialogPrompt

    // MARK: feed.list

    /// `{items}`: the pending dialogs, then (with `pendingOnly` false) those this desk answered.
    func list(pendingOnly: Bool) async -> JSONValue {
        var items: [JSONValue] = []
        if let line = await open() {
            defer { line.close() }
            items = await line.pendingPrompts().map { item($0) }
        }
        items += asks?.items() ?? []
        if !pendingOnly { items += answered.reversed() }
        return .object(["items": .array(items)])
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
        if let asks, asks.owns(id) { return try remembering(asks.reply(id, selection: mode, params: params), id) }
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
        if let asks, asks.owns(id) {
            // One item: its choice, given as CHOICE or ITEM=CHOICE.
            let choice = selections.count == 1 ? String(selections[0].split(separator: "=", maxSplits: 1).last ?? "") : ""
            return try remembering(asks.reply(id, selection: choice, params: params), id)
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
                "cmux couldn't confirm the answer came from you; answer the question in the cmux window"), data: ["request_id": .string(id)])
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
            throw ControlError(code: "unavailable", message: Self.text("agentDialogs.noAcpmux", "No agent daemon answers in this app"))
        }
        guard let prompt = await line.pendingPrompts().first(where: { $0.permission == id }) else {
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

    /// An app ask's answer, listed with `pending_only: false` like acpmux's.
    private func remembering(_ reply: JSONValue, _ id: String) -> JSONValue {
        answered.append(.object(["id": .string(id), "request_id": .string(id), "source": "cmux",
                                 "status": reply.objectValue?["status"] ?? "answered"]))
        if answered.count > Self.answeredLimit { answered.removeFirst(answered.count - Self.answeredLimit) }
        return reply
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

/// Asks the app itself shows in a chat (not acpmux prompts), listed and answered through the desk.
/// Each decides who may answer it: the desk only routes.
@MainActor
protocol AgentDialogAppAsks: AnyObject {
    /// Whether dialog `id` is one of these asks.
    func owns(_ id: String) -> Bool
    /// The pending asks, as `feed.list` items.
    func items() -> [JSONValue]
    /// Answers ask `id` with `selection` (an option's id or label, or a permission mode) for the
    /// request `params` (its `origin` and `caller` say who answers); throws a refusal.
    func reply(_ id: String, selection: String, params: [String: JSONValue]) throws -> JSONValue
}

extension AgentDialogPrompt {
    /// The prompt as a question this socket may answer; nil for a tool permission.
    var question: AgentQuestion? {
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let json = try? AgentQuestionJSON(data: data),
              let question = AgentQuestion(permissionRequest: json, permissionId: permission, session: session),
              question.source.harness != .acp else { return nil }
        return question
    }
}

private extension JSONValue {
    /// The text, or null.
    static func orNull(_ text: String?) -> JSONValue { text.map(JSONValue.string) ?? .null }
}
