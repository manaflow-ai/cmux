import Foundation

/// Decodes the feed owner's JSON (backend `FeedItem`, plans/cmux-next/feed.md
/// 3.1: snake_case, times in ms) into the client model. Pure; unknown or
/// malformed parts fall back to the generic shapes so one odd item never
/// hides the rest of the feed.
nonisolated enum FeedWireDecode {
    typealias Object = [String: Any]

    static func json(_ any: Any?) -> FeedJSON {
        switch any {
        case nil, is NSNull: return .null
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): return .bool(n.boolValue)
        case let n as NSNumber: return .number(n.doubleValue)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map { json($0) })
        case let o as Object: return .object(o.mapValues { json($0) })
        default: return .null
        }
    }

    static func date(_ any: Any?) -> Date? {
        guard let n = any as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: n.doubleValue / 1000)
    }

    private static func strings(_ any: Any?) -> [String] { (any as? [Any])?.compactMap { $0 as? String } ?? [] }

    static func item(_ o: Object) -> FeedItem? {
        guard let id = o["id"] as? String, let title = o["title"] as? String,
              let poster = o["poster"] as? Object, let created = date(o["created_at"]) else { return nil }
        let kind = o["kind"] as? String ?? "notice"
        let prompt = prompt(kind: kind, o["prompt"] as? Object ?? [:], answerSchema: o["answer_schema"])
        let home = o["home"] as? String ?? "cloud"
        return FeedItem(
            id: id,
            home: home.hasPrefix("local:") ? .local(install: String(home.dropFirst(6))) : .cloud,
            title: title,
            body: o["body"] as? String ?? "",
            prompt: prompt,
            priority: (o["priority"] as? String).flatMap(FeedPriority.init(rawValue:)),
            dedupeKey: o["dedupe_key"] as? String,
            thread: o["thread"] as? String,
            context: context(o["context"] as? Object ?? [:]),
            attachments: ((o["attachments"] as? [Object]) ?? []).compactMap(attachment),
            actions: ((o["actions"] as? [Object]) ?? []).compactMap(action),
            expiresAt: date(o["expires_at"]),
            poster: FeedPoster(kind: FeedPoster.Kind(rawValue: poster["kind"] as? String ?? "") ?? .agent,
                               label: poster["label"] as? String ?? "", harness: poster["harness"] as? String,
                               identity: poster["scope"] as? String, host: nil),
            state: FeedItemState(rawValue: o["state"] as? String ?? "") ?? .open,
            answer: (o["answer"] as? Object).flatMap { answerRecord($0, prompt: prompt) },
            cancel: (o["cancel"] as? Object).flatMap(cancel),
            readAt: date(o["read_at"]), seenAt: date(o["seen_at"]), archivedAt: date(o["archived_at"]),
            snoozedUntil: date(o["snoozed_until"]),
            count: (o["count"] as? Int) ?? 1, revision: (o["revision"] as? Int) ?? 1,
            createdAt: created, updatedAt: date(o["updated_at"]), closedAt: date(o["closed_at"])
        )
    }

    static func context(_ o: Object) -> FeedContext {
        FeedContext(host: o["host"] as? String, workspace: o["workspace"] as? String, tab: o["tab"] as? String,
                    terminal: o["terminal"] as? String, browserTab: o["browser_tab"] as? String,
                    acpSession: o["acp_session"] as? String, task: o["task"] as? String,
                    url: (o["url"] as? String).flatMap(URL.init(string:)))
    }

    static func attachment(_ o: Object) -> FeedAttachment? {
        guard let id = o["id"] as? String, let name = o["name"] as? String else { return nil }
        return FeedAttachment(id: id, name: name, mime: o["mime"] as? String ?? "application/octet-stream", size: o["size"] as? Int ?? 0)
    }

    static func action(_ o: Object) -> FeedAction? {
        guard let id = o["id"] as? String, let label = o["label"] as? String else { return nil }
        let style = FeedAction.Style(rawValue: o["style"] as? String ?? "") ?? .default
        return FeedAction(id: id, label: label, style: style, answer: o["answer"].map { json($0) })
    }

    static func cancel(_ o: Object) -> FeedCancelRecord? {
        guard let reason = (o["reason"] as? String).flatMap(FeedCancelRecord.Reason.init(rawValue:)), let at = date(o["at"]) else { return nil }
        return FeedCancelRecord(reason: reason, by: o["by"] as? String ?? "", at: at, note: o["note"] as? String)
    }

    static func answerRecord(_ o: Object, prompt: FeedPrompt) -> FeedAnswerRecord? {
        guard let at = date(o["at"]) else { return nil }
        return FeedAnswerRecord(value: answer(o["value"], prompt: prompt), by: o["by"] as? String ?? "", device: o["device"] as? String ?? "", at: at)
    }

    // MARK: - Prompts

    static func prompt(kind: String, _ p: Object, answerSchema: Any?) -> FeedPrompt {
        let s = { (key: String) in p[key] as? String }
        switch kind {
        case "notice": return .notice
        case "question":
            return .question(.init(question: s("question") ?? "", suggestions: strings(p["suggestions"]), multiline: p["multiline"] as? Bool ?? false))
        case "choice":
            let questions = ((p["questions"] as? [Object]) ?? []).map { q in
                FeedPrompt.ChoiceQuestion(
                    id: q["id"] as? String ?? "", question: q["question"] as? String ?? "", header: q["header"] as? String,
                    options: ((q["options"] as? [Object]) ?? []).map {
                        .init(id: $0["id"] as? String ?? "", label: $0["label"] as? String ?? "", detail: $0["description"] as? String)
                    },
                    multi: q["multi"] as? Bool ?? false, allowOther: q["allow_other"] as? Bool ?? false)
            }
            return .choice(.init(questions: questions))
        case "approve":
            let a = p["action"] as? Object ?? [:]
            let action = FeedPrompt.Approve.Action(
                type: FeedPrompt.Approve.ActionType(rawValue: a["type"] as? String ?? "") ?? .custom, summary: a["summary"] as? String ?? "",
                command: a["command"] as? String, cwd: a["cwd"] as? String, tool: a["tool"] as? String, diff: a["diff"] as? String, risk: a["risk"] as? String)
            return .approve(.init(action: action, scopes: strings(p["scopes"]).compactMap(FeedApproveScope.init(rawValue:))))
        case "confirm":
            return .confirm(.init(statement: s("statement") ?? "", confirmLabel: s("confirm_label"), cancelLabel: s("cancel_label"),
                                  destructive: p["destructive"] as? Bool ?? false))
        case "sign-in":
            return .signIn(.init(origin: s("origin") ?? "", url: s("url").flatMap(URL.init(string:)), browserTab: s("browser_tab") ?? "", reason: s("reason") ?? ""))
        case "passkey":
            return .passkey(.init(origin: s("origin") ?? "", rpID: s("rp_id"), ceremony: FeedPrompt.Passkey.Ceremony(rawValue: s("ceremony") ?? "") ?? .get,
                                  browserTab: s("browser_tab") ?? "", reason: s("reason") ?? ""))
        case "review":
            return .review(.init(subject: FeedPrompt.Review.Subject(rawValue: s("subject") ?? "") ?? .document, ref: s("ref") ?? "", checklist: strings(p["checklist"])))
        case "input":
            return .input(.init(fields: inputFields(p["schema"] as? Object ?? [:])))
        case "file":
            return .file(.init(purpose: s("purpose") ?? "", accept: strings(p["accept"]), multiple: p["multiple"] as? Bool ?? false,
                               maxBytes: p["max_bytes"] as? Int ?? 50 << 20))
        case "handoff":
            return .handoff(.init(reason: s("reason") ?? "", resumeHint: s("resume_hint")))
        default:
            return .custom(kind: kind, prompt: json(p), answerSchema: answerSchema.map { json($0) })
        }
    }

    static func inputFields(_ schema: Object) -> [FeedPrompt.InputField] {
        let props = schema["properties"] as? Object ?? [:]
        let required = Set(strings(schema["required"]))
        return props.keys.sorted().compactMap { name in
            guard let f = props[name] as? Object else { return nil }
            let type: FeedPrompt.InputField.FieldType
            switch f["type"] as? String {
            case "number": type = .number
            case "integer": type = .integer
            case "boolean": type = .boolean
            case "array": type = .choice(strings((f["items"] as? Object)?["enum"]))
            default: type = (f["enum"] as? [Any]).map { .choice(strings($0)) } ?? .string(format: f["format"] as? String)
            }
            return .init(id: name, title: f["title"] as? String ?? name, type: type, required: required.contains(name))
        }
    }

    // MARK: - Answers

    static func answer(_ any: Any?, prompt: FeedPrompt) -> FeedAnswerValue {
        let o = any as? Object ?? [:]
        let s = { (key: String) in o[key] as? String }
        switch prompt {
        case .question: return .text(s("text") ?? "")
        case .choice:
            let answers = (o["answers"] as? Object ?? [:]).compactMapValues { v -> FeedChoiceSelection? in
                guard let v = v as? Object else { return nil }
                return FeedChoiceSelection(selected: strings(v["selected"]), other: v["other"] as? String)
            }
            return .choice(answers)
        case .approve:
            return .approve(.init(FeedAnswerValue.Decision.Outcome(rawValue: s("decision") ?? "") ?? .deny,
                                  scope: s("scope").flatMap(FeedApproveScope.init(rawValue:)), reason: s("reason")))
        case .confirm: return .confirm(o["confirmed"] as? Bool ?? false)
        case .signIn: return .signIn(FeedAnswerValue.BrowserStatus(rawValue: s("status") ?? "") ?? .failed)
        case .passkey: return .passkey(FeedAnswerValue.BrowserStatus(rawValue: s("status") ?? "") ?? .failed)
        case .review: return .review(FeedAnswerValue.Verdict(rawValue: s("verdict") ?? "") ?? .comment, comment: s("comment"))
        case .input: return .input(o.mapValues { json($0) })
        case .file: return .files(((o["files"] as? [Object]) ?? []).compactMap(attachment))
        case .handoff: return .handoff(FeedAnswerValue.HandoffStatus(rawValue: s("status") ?? "") ?? .declined, note: s("note"))
        case .notice, .custom: return .custom(json(any))
        }
    }
}
