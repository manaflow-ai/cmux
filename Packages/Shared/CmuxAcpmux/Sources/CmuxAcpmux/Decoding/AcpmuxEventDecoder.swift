public import CmuxConversation

/// Translates acpmux log records into ``ConversationEvent``s.
///
/// This is the only place that knows acpmux's record shapes. Records the GUI
/// has no use for decode to nothing; acpmux-only facts worth showing (a
/// failover to another account, a restored session) become
/// ``ExtensionItem``s in the `acpmux` namespace, so the GUI can render them
/// with localized text.
public struct AcpmuxEventDecoder: Sendable {
    /// Creates a decoder.
    public init() {}

    /// Decodes one record.
    /// - Parameter r: The record.
    /// - Returns: The envelope, or `nil` when the record means nothing to the GUI.
    public func decode(_ r: AcpmuxRecord) -> ConversationEnvelope? {
        guard let event = event(r) else { return nil }
        return ConversationEnvelope(cursor: ConversationCursor(order: r.seq), timestamp: r.at, event: event)
    }

    /// Decodes records, keeping those that mean something to the GUI.
    /// - Parameter records: The records.
    /// - Returns: Their envelopes, in record order.
    public func decode(_ records: [AcpmuxRecord]) -> [ConversationEnvelope] {
        records.compactMap(decode)
    }

    private func text(_ content: JSONValue?) -> String {
        guard let content else { return "" }
        switch content {
        case let .string(s): return s
        case let .array(a): return a.map(text).joined()
        case .object:
            if let t = content["text"]?.stringValue { return t }
            if let c = content["content"] { return text(c) }
            if let d = content["diff"] ?? (content["type"]?.stringValue == "diff" ? content : nil) {
                return [d["path"]?.stringValue, d["newText"]?.stringValue].compactMap { $0 }.joined(separator: "\n")
            }
            return ""
        default: return ""
        }
    }

    private func attachments(_ v: JSONValue?, state: AttachmentState = .uploading(received: 0)) -> [ConversationAttachment] {
        (v?.arrayValue ?? []).compactMap { attachment($0, state: state) }
    }

    private func attachment(_ v: JSONValue, state: AttachmentState) -> ConversationAttachment? {
        guard let id = v["uploadId"]?.stringValue else { return nil }
        return ConversationAttachment(uploadID: id, name: v["name"]?.stringValue ?? id, mimeType: v["mimeType"]?.stringValue ?? "application/octet-stream", size: v["size"]?.uint64Value ?? 0, sha256: v["sha256"]?.stringValue ?? "", thumbnailUploadID: v["thumbnailUploadId"]?.stringValue, state: state)
    }

    private func cmid(_ v: JSONValue) -> ClientMessageID? {
        v["clientMessageId"]?.stringValue.map(ClientMessageID.init)
    }

    private func event(_ r: AcpmuxRecord) -> ConversationEvent? {
        if r.dir == "in" {
            guard !r.kind.hasSuffix(".replay"), r.msg["method"]?.stringValue == "session/update", let u = r.msg["params"]?["update"] else { return nil }
            return update(u)
        }
        guard r.dir == "mux" else { return nil }
        let m = r.msg
        switch r.kind {
        case "user_message":
            return .userMessage(clientMessageID: cmid(m), text: m["text"]?.stringValue ?? "", attachments: attachments(m["attachments"]), steer: m["steer"]?.boolValue ?? false)
        case "queued":
            return .userMessageQueued(clientMessageID: cmid(m), text: m["text"]?.stringValue ?? "", attachments: attachments(m["attachments"]), position: Int(m["position"]?.uint64Value ?? 1), held: m["held"]?.boolValue ?? false)
        case "queue":
            let entries = (m["entries"]?.arrayValue ?? []).map { e in
                QueuedPrompt(clientMessageID: cmid(e), position: Int(e["position"]?.uint64Value ?? 0), ticket: e["ticket"]?.uint64Value)
            }
            return .queueChanged(entries)
        case "dequeued":
            return .userMessageDequeued(clientMessageID: cmid(m), text: m["text"]?.stringValue ?? "")
        case "prompt_failed":
            let failed = (m["attachments"]?.arrayValue ?? []).compactMap(\.stringValue)
            return .userMessageFailed(clientMessageID: cmid(m), text: m["text"]?.stringValue ?? "", attachments: attachments(m["files"]), failedUploadIDs: failed)
        case "attachment":
            let state: AttachmentState
            switch m["state"]?.stringValue {
            case "uploaded": state = .uploaded
            case "failed": state = .failed
            case "missing": state = .missing
            default: state = .uploading(received: m["received"]?.uint64Value ?? 0)
            }
            return attachment(m, state: state).map(ConversationEvent.attachmentChanged)
        case "attachment_progress":
            guard let id = m["uploadId"]?.stringValue else { return nil }
            return .attachmentProgress(uploadID: id, received: m["received"]?.uint64Value ?? 0)
        case "permission_request":
            guard let id = m["permissionId"]?.stringValue else { return nil }
            let req = m["request"] ?? .null
            let options = (req["options"]?.arrayValue ?? []).compactMap { o -> ApprovalOption? in
                guard let oid = o["optionId"]?.stringValue else { return nil }
                return ApprovalOption(id: oid, label: o["name"]?.stringValue ?? oid, kind: o["kind"]?.stringValue ?? "")
            }
            return .approvalRequested(ApprovalRequest(id: id, title: req["toolCall"]?["title"]?.stringValue ?? "", options: options))
        case "permission_decision":
            guard let id = m["permissionId"]?.stringValue else { return nil }
            return .approvalResolved(id: id, optionID: m["outcome"]?["optionId"]?.stringValue)
        case "turn_started":
            return .turnStarted(clientMessageID: cmid(m))
        case "turn_result":
            let failed = m["status"]?.stringValue == "failed"
            return .turnEnded(stopReason: m["stopReason"]?.stringValue ?? m["status"]?.stringValue, error: failed ? (m["error"]?.stringValue ?? "") : nil)
        case "status":
            return m["status"]?.stringValue.map { .statusChanged(ConversationStatus(raw: $0)) }
        case "mode":
            return m["modeId"]?.stringValue.map(ConversationEvent.modeChanged)
        case "model":
            return m["modelId"]?.stringValue.map(ConversationEvent.modelChanged)
        case "failover", "resumed", "forked", "imported":
            return .extension(ExtensionItem(namespace: "acpmux", type: r.kind, payload: m))
        default:
            return nil
        }
    }

    private func update(_ u: JSONValue) -> ConversationEvent? {
        switch u["sessionUpdate"]?.stringValue {
        case "agent_message_chunk":
            return .assistantText(text(u["content"]))
        case "agent_thought_chunk":
            return .reasoningText(text(u["content"]))
        case "tool_call":
            guard let id = u["toolCallId"]?.stringValue else { return nil }
            return .activityStarted(id: id, ActivityItem(kind: u["kind"]?.stringValue ?? "other", title: u["title"]?.stringValue ?? "", status: u["status"]?.stringValue ?? "pending", detail: text(u["content"])))
        case "tool_call_update":
            guard let id = u["toolCallId"]?.stringValue else { return nil }
            let detail = u["content"].map(text)
            return .activityUpdated(id: id, status: u["status"]?.stringValue, title: u["title"]?.stringValue, detail: detail.flatMap { $0.isEmpty ? nil : $0 })
        case "plan":
            let entries = (u["entries"]?.arrayValue ?? []).map { PlanEntry(content: $0["content"]?.stringValue ?? "", status: $0["status"]?.stringValue ?? "pending") }
            return .plan(entries)
        case "usage_update":
            guard let used = u["used"]?.uint64Value else { return nil }
            return .usage(used: used, size: u["size"]?.uint64Value)
        case "current_mode_update":
            return u["currentModeId"]?.stringValue.map(ConversationEvent.modeChanged)
        default:
            return nil
        }
    }

    /// Reads a session summary from `_acpmux/sessions`, `_acpmux/watch` or
    /// `_acpmux/session_changed`.
    /// - Parameter v: The summary object.
    /// - Returns: The summary, or `nil` without a session id.
    public func summary(_ v: JSONValue) -> ConversationSummary? {
        guard let id = v["sessionId"]?.stringValue else { return nil }
        let peer = v["peer"]?.stringValue
        let name = v["name"]?.stringValue ?? id
        return ConversationSummary(
            id: ConversationID(id),
            name: peer.map { "\($0)/\(name)" } ?? name,
            title: v["title"]?.stringValue,
            status: ConversationStatus(raw: v["status"]?.stringValue ?? "idle"),
            agent: v["harness"]?.stringValue,
            workingDirectory: v["cwd"]?.stringValue,
            updatedAt: v["updatedAt"]?.uint64Value ?? 0,
            unread: v["unread"]?.boolValue ?? false,
            pendingApprovals: Int(v["pendingPermissions"]?.uint64Value ?? 0),
            queued: Int(v["queued"]?.uint64Value ?? 0)
        )
    }

    /// Reads the title, status, mode and model from a session summary.
    /// - Parameter v: The summary object.
    /// - Returns: The metadata.
    public func metadata(_ v: JSONValue) -> ConversationMetadata {
        ConversationMetadata(
            title: v["title"]?.stringValue,
            status: v["status"]?.stringValue.map(ConversationStatus.init(raw:)),
            mode: v["currentModeId"]?.stringValue,
            model: v["model"]?.stringValue ?? v["model"]?["modelId"]?.stringValue
        )
    }
}
