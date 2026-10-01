import CmuxConversation
import CmuxNextAcpmux
import CmuxNextConversationUI
import Foundation

/// Debug-socket support: a JSON report of the agent GUI and the actions a
/// verification script drives (no synthesized input).
extension AgentService {
    /// Everything a check needs to see, as JSON.
    func debugReport() -> Data {
        var report: [String: Any] = [
            "supervisor": String(describing: supervisorState),
            "socket": configuration?.socketPath ?? NSNull(),
            "home": configuration?.home.path ?? NSNull(),
            "keepAwakeEnabled": keepAwakeDuringTurns,
            "keepAwakeHeld": isHoldingKeepAwake,
            "busyConversations": busyConversations,
            "windowOpen": window?.window?.isVisible ?? false,
        ]
        if let window {
            report["conversations"] = window.conversations.map { ["id": $0.id.rawValue, "title": $0.title ?? $0.name, "status": String(describing: $0.status), "agent": $0.agent ?? ""] }
            if let model = window.currentModel {
                report["current"] = Self.describe(model)
            }
        }
        return (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private static func describe(_ model: ConversationModel) -> [String: Any] {
        let state = model.state
        let items: [[String: Any]] = state.items.map { item in
            var d: [String: Any] = ["id": item.id]
            switch item.kind {
            case let .message(m):
                d["kind"] = m.role == .user ? "user" : "assistant"
                d["text"] = m.text
                if let delivery = m.delivery { d["delivery"] = String(describing: delivery) }
                if !m.attachmentIDs.isEmpty { d["attachments"] = m.attachmentIDs }
            case let .reasoning(t): d["kind"] = "reasoning"; d["text"] = t
            case let .activity(a): d["kind"] = "activity"; d["text"] = a.title; d["status"] = a.status
            case .plan: d["kind"] = "plan"
            case let .approval(r): d["kind"] = "approval"; d["text"] = r.title; d["requestId"] = r.id; d["decision"] = r.decision ?? NSNull(); d["options"] = r.options.map(\.id)
            case let .notice(t): d["kind"] = "notice"; d["text"] = t
            case let .error(t): d["kind"] = "error"; d["text"] = t
            case .turnEnded: d["kind"] = "turnEnded"
            case let .extension(x): d["kind"] = "extension"; d["text"] = "\(x.namespace).\(x.type)"
            }
            return d
        }
        return [
            "id": model.conversationID?.rawValue ?? NSNull(),
            "connection": String(describing: model.connection),
            "status": String(describing: state.status),
            "deleted": state.isDeleted,
            "hasOlder": state.hasOlder,
            "items": items,
            "queue": state.queue.map { ["clientMessageId": $0.clientMessageID?.rawValue ?? "", "position": $0.position] },
            "attachments": Dictionary(uniqueKeysWithValues: state.attachments.map { ($0.key, String(describing: $0.value.state)) }),
        ]
    }

    /// Opens the window on a new conversation.
    func debugNew() {
        showWindow()?.newConversation()
    }

    /// Opens a conversation by id.
    func debugOpen(_ id: String) {
        showWindow()?.open(ConversationID(id))
    }

    /// Sends a message (staging `files` first) on the open conversation.
    /// - Returns: The message's client id, or nil without an open conversation.
    func debugSend(text: String, files: [String], steer: Bool) async -> String? {
        guard let window = showWindow(), let model = window.currentModel else { return nil }
        let preparer = AttachmentDebugPreparer()
        var attachments: [OutgoingAttachment] = []
        for path in files {
            if let a = try? await preparer.prepare(URL(fileURLWithPath: path)) { attachments.append(a) }
        }
        return model.send(text: text, attachments: attachments, steer: steer).rawValue
    }

    /// Removes a queued message (the alert is the UI's; this is the check's path).
    func debugDequeue(_ id: String) async throws {
        try await showWindow()?.currentModel?.dequeue(ClientMessageID(id))
    }

    /// Retries a failed message.
    func debugRetry(_ id: String) async throws {
        try await showWindow()?.currentModel?.retry(ClientMessageID(id))
    }

    /// Answers an approval request.
    func debugAnswer(request: String, option: String) async throws {
        try await showWindow()?.currentModel?.answer(request, optionID: option)
    }

    /// Runs a command (`stop`, `delete`, `cancel`) on the open conversation.
    func debugCommand(_ name: String) async throws {
        guard let model = showWindow()?.currentModel else { return }
        switch name {
        case "cancel": try await model.cancelTurn()
        case "stop": try await model.perform(.stop)
        case "delete": try await model.perform(.delete)
        default: break
        }
    }
}

/// Size and SHA-256 of a file for a debug send (no preview).
nonisolated struct AttachmentDebugPreparer {
    func prepare(_ url: URL) async throws -> OutgoingAttachment {
        try await Task.detached {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256Hasher()
            var total: UInt64 = 0
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(chunk)
                total += UInt64(chunk.count)
            }
            let mime = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType) ?? "application/octet-stream"
            return OutgoingAttachment(uploadID: "u-" + UUID().uuidString.lowercased(), fileURL: url, name: url.lastPathComponent, mimeType: mime, size: total, sha256: hasher.hex)
        }.value
    }
}
