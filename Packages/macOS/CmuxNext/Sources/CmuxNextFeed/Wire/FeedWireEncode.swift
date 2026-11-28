import Foundation

/// Encodes client intents as feed owner op params (backend `feed.*` ops,
/// plans/cmux-next/feed.md section 6). Pure; JSON-serializable values only.
nonisolated enum FeedWireEncode {
    static func any(_ j: FeedJSON) -> Any {
        switch j {
        case .null: NSNull()
        case let .bool(b): b
        case let .number(n): n
        case let .string(s): s
        case let .array(a): a.map(any)
        case let .object(o): o.mapValues(any)
        }
    }

    static func ms(_ date: Date) -> Int { Int((date.timeIntervalSince1970 * 1000).rounded()) }

    /// Encodes an integration item for the same `feed.post` owner operation
    /// used by hooks and notifications. It intentionally includes only the
    /// item fields that the owner accepts from a poster.
    static func post(_ item: FeedItem) -> (params: [String: Any], key: String) {
        var params: [String: Any] = [
            "type": item.isRequest ? "request" : "notice",
            "kind": item.kind,
            "title": String(item.title.prefix(200)),
            "body": String(item.body.prefix(4096)),
            "priority": item.priority.rawValue,
            "poster": ["kind": item.poster.kind.rawValue, "label": String(item.poster.label.prefix(80))],
        ]
        if let dedupeKey = item.dedupeKey { params["dedupe_key"] = String(dedupeKey.prefix(200)) }
        if let thread = item.thread { params["thread"] = String(thread.prefix(200)) }
        if let context = context(item.context) { params["context"] = context }
        if let expiresAt = item.expiresAt {
            params["expires_in_ms"] = max(0, Int((expiresAt.timeIntervalSinceNow * 1000).rounded()))
        }
        if case let .review(review) = item.prompt {
            params["prompt"] = [
                "subject": review.subject.rawValue,
                "ref": review.ref,
                "checklist": review.checklist,
            ]
        }
        if !item.actions.isEmpty {
            params["actions"] = item.actions.map { action in
                var value: [String: Any] = ["id": action.id, "label": action.label, "style": action.style.rawValue]
                if let answer = action.answer { value["answer"] = any(answer) }
                return value
            }
        }
        let key = "github:\(item.dedupeKey ?? item.id)"
        return (params, String(key.prefix(200)))
    }

    private static func context(_ context: FeedContext) -> [String: Any]? {
        var value: [String: Any] = [:]
        if let host = context.host { value["host"] = host }
        if let workspace = context.workspace { value["workspace"] = workspace }
        if let tab = context.tab { value["tab"] = tab }
        if let terminal = context.terminal { value["terminal"] = terminal }
        if let browserTab = context.browserTab { value["browser_tab"] = browserTab }
        if let acpSession = context.acpSession { value["acp_session"] = acpSession }
        if let task = context.task { value["task"] = task }
        if let url = context.url { value["url"] = url.absoluteString }
        return value.isEmpty ? nil : value
    }

    /// The owner's answer value for a kind (the kind's answer schema).
    static func answer(_ value: FeedAnswerValue) -> Any {
        func compact(_ pairs: [(String, Any?)]) -> [String: Any] {
            var o: [String: Any] = [:]
            for (k, v) in pairs { if let v { o[k] = v } }
            return o
        }
        switch value {
        case let .text(text): return ["text": text]
        case let .choice(answers):
            return ["answers": answers.mapValues { compact([("selected", $0.selected), ("other", $0.other)]) }]
        case let .approve(d):
            return compact([("decision", d.outcome.rawValue), ("scope", d.outcome == .allow ? d.scope?.rawValue : nil), ("reason", d.reason)])
        case let .confirm(confirmed): return ["confirmed": confirmed]
        case let .signIn(status), let .passkey(status): return ["status": status.rawValue]
        case let .review(verdict, comment): return compact([("verdict", verdict.rawValue), ("comment", comment)])
        case let .input(fields): return fields.mapValues(any)
        case let .files(files): return ["files": files.map { ["id": $0.id, "name": $0.name, "mime": $0.mime, "size": $0.size] }]
        case let .handoff(status, note): return compact([("status", status.rawValue), ("note", note)])
        case let .custom(json): return any(json)
        }
    }

    /// `(op, params)` for one intent. `markAllRead` sends the owner's `all`
    /// (it also reads an item posted between the click and the commit).
    static func op(_ intent: FeedIntent, unreadBefore: (Date) -> [String]) -> (op: String, params: [String: Any])? {
        switch intent.kind {
        case let .answer(item, value): return (intent.op, ["item": item, "answer": answer(value)])
        case let .decline(item): return (intent.op, ["item": item, "reason": "declined"])
        case let .read(items): return items.isEmpty ? nil : (intent.op, ["items": Array(items.prefix(256))])
        case let .archive(items): return items.isEmpty ? nil : (intent.op, ["items": Array(items.prefix(256))])
        case let .snooze(items, until): return items.isEmpty ? nil : (intent.op, ["items": Array(items.prefix(256)), "until": ms(until)])
        case let .markAllRead(before):
            // The owner reads every unread item at commit (no 256-id cap, no stale id refusing the whole op).
            return unreadBefore(before).isEmpty ? nil : (intent.op, ["all": true])
        }
    }

    /// A reject frame as the client's typed reject.
    static func reject(code: String, message: String, details: [String: Any]?) -> FeedReject {
        switch code {
        case "feed.closed":
            if let o = details?["item"] as? [String: Any], let item = FeedWireDecode.item(o) { return .closed(item) }
            return .other(message)
        case "feed.moving": return .moving
        case "validation.invalid": return .invalid(message)
        default: return .other("\(code): \(message)")
        }
    }
}
