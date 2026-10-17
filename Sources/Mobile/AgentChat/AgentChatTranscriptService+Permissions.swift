import CMUXAgentLaunch
import CmuxAgentChat
import Foundation

/// Hook-backed permission cards for mobile chat.
///
/// Agent JSONL transcripts intentionally omit the interactive approval prompt,
/// so these messages live beside the transcript cache and are merged into
/// history pages. Their stable message ids let the answer RPC resolve exactly
/// the card the user tapped, even when multiple approvals are pending.
extension AgentChatTranscriptService {
    /// Inserts one permission request, coalescing hook retries for the same
    /// request. A provider without a request id gets a stable fingerprint while
    /// it is pending; once that request resolves a later identical command is a
    /// fresh card.
    fileprivate func notePermissionRequest(
        _ event: WorkstreamEvent,
        sessionID: String,
        agentKind: ChatAgentKind
    ) {
        let rawRequestID = permissionRequestID(from: event)
        let fingerprint = permissionFingerprint(for: event, rawRequestID: rawRequestID)
        var records = permissionRecordsBySessionID[sessionID, default: [:]]
        if records.values.contains(where: {
            $0.resolution == nil
                && ($0.identity == fingerprint
                    || (rawRequestID != nil && $0.rawRequestID == rawRequestID))
        }) {
            return
        }

        let ordinal = nextPermissionOrdinalBySessionID[sessionID, default: 0]
        nextPermissionOrdinalBySessionID[sessionID] = ordinal + 1
        let identity = existingResolvedIdentity(
            base: fingerprint,
            records: records,
            ordinal: ordinal
        )
        let messageID = "permission:\(sessionID):\(identity)"
        let title = "\(agentKind.displayName) wants permission"
        let subject = permissionSubject(toolName: event.toolName, toolInputJSON: event.toolInputJSON)
        // Reserve a separate seq range so synthetic cards never collide with
        // transcript line numbers. The history merge still honors before_seq
        // and keeps the card in the newest page.
        let seq = 1_000_000_000 + ordinal
        let record = PermissionRecord(
            identity: identity,
            rawRequestID: rawRequestID,
            messageID: messageID,
            seq: seq,
            timestamp: event.receivedAt,
            title: title,
            subject: subject,
            resolution: nil
        )
        records[identity] = record
        permissionRecordsBySessionID[sessionID] = records
        guard chatEventsAreSubscribed else { return }
        emitChatFrame(ChatSessionEventFrame(sessionID: sessionID, event: .appended([record.message])))
    }

    /// Marks a card resolved after the terminal answer was accepted. The
    /// updated event freezes the card on all phones; retries are idempotent.
    @discardableResult
    func resolvePermission(
        sessionID: String,
        requestID: String?,
        optionIndex: Int
    ) -> Bool {
        guard optionIndex >= 0 else { return false }
        guard var records = permissionRecordsBySessionID[sessionID], !records.isEmpty else {
            return false
        }
        let candidate = permissionCandidate(
            records: records,
            requestID: requestID
        )
        guard let candidate else { return false }
        guard candidate.resolution == nil else { return true }
        var updated = candidate
        updated.resolution = optionIndex == 0 ? .approved : .denied
        records[updated.identity] = updated
        permissionRecordsBySessionID[sessionID] = records
        if chatEventsAreSubscribed {
            emitChatFrame(ChatSessionEventFrame(sessionID: sessionID, event: .updated([updated.message])))
        }
        return true
    }

    /// Expires cards when a turn/session stops without a mobile answer.
    @discardableResult
    fileprivate func expirePermissionRequests(sessionID: String) -> Bool {
        guard var records = permissionRecordsBySessionID[sessionID], !records.isEmpty else {
            return false
        }
        var updates: [ChatMessage] = []
        var didChange = false
        var canonical: [String: PermissionRecord] = [:]
        for (key, value) in records {
            var next = value
            if next.resolution == nil {
                next.resolution = .expired
                didChange = true
                updates.append(next.message)
            }
            canonical[key] = next
        }
        guard didChange else { return false }
        permissionRecordsBySessionID[sessionID] = canonical
        if chatEventsAreSubscribed {
            emitChatFrame(ChatSessionEventFrame(sessionID: sessionID, event: .updated(updates)))
        }
        return true
    }

    fileprivate func historyPageWithPermissions(
        _ page: ChatHistoryPage,
        sessionID: String,
        beforeSeq: Int?,
        limit: Int
    ) -> ChatHistoryPage {
        let permissions = permissionRecordsBySessionID[sessionID, default: [:]]
            .values
            .map(\.message)
        let merged = mergePermissionMessages(
            transcript: page.messages,
            permissions: Array(permissions),
            beforeSeq: beforeSeq,
            limit: limit
        )
        return ChatHistoryPage(
            messages: merged.messages,
            hasMore: page.hasMore || merged.hasMore,
            terminalBlocks: page.terminalBlocks
        )
    }

    fileprivate func permissionOnlyHistory(
        sessionID: String,
        beforeSeq: Int?,
        limit: Int
    ) -> ChatHistoryPage? {
        guard permissionRecordsBySessionID[sessionID] != nil else { return nil }
        let merged = mergePermissionMessages(
            transcript: [],
            permissions: permissionRecordsBySessionID[sessionID, default: [:]]
                .values
                .map(\.message),
            beforeSeq: beforeSeq,
            limit: limit
        )
        return ChatHistoryPage(messages: merged.messages, hasMore: merged.hasMore)
    }

    private func mergePermissionMessages(
        transcript: [ChatMessage],
        permissions: [ChatMessage],
        beforeSeq: Int?,
        limit: Int
    ) -> (messages: [ChatMessage], hasMore: Bool) {
        let all = (transcript + permissions)
            .filter { beforeSeq.map { $0.seq < $1 } ?? true }
            .sorted {
                if $0.seq != $1.seq { return $0.seq < $1.seq }
                return $0.timestamp < $1.timestamp
            }
        guard all.count > limit else { return (all, false) }
        return (Array(all.suffix(limit)), true)
    }

    private func permissionCandidate(
        records: [String: PermissionRecord],
        requestID: String?
    ) -> PermissionRecord? {
        let unique = records.values.reduce(into: [String: PermissionRecord]()) { result, record in
            result[record.messageID] = record
        }
        if let requestID, !requestID.isEmpty {
            if let direct = unique[requestID] { return direct }
            if let direct = unique.values.first(where: { $0.identity == requestID || $0.rawRequestID == requestID }) {
                return direct
            }
            if requestID.hasPrefix("permission:"),
               let direct = unique.values.first(where: { $0.messageID == requestID }) {
                return direct
            }
        }
        return unique.values
            .filter { $0.resolution == nil }
            .max { lhs, rhs in lhs.seq < rhs.seq }
    }

    private func permissionRequestID(from event: WorkstreamEvent) -> String? {
        if let id = event.requestId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return id
        }
        guard let raw = event.extraFieldsJSON,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let keys = ["request_id", "requestId", "permission_request_id", "permissionRequestId", "tool_use_id", "toolUseId", "event_id", "eventId"]
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private func permissionFingerprint(for event: WorkstreamEvent, rawRequestID: String?) -> String {
        if let rawRequestID { return "request:\(rawRequestID)" }
        let tool = event.toolName ?? "tool"
        let input = event.toolInputJSON ?? ""
        return "fingerprint:\(tool):\(input)"
    }

    private func existingResolvedIdentity(
        base: String,
        records: [String: PermissionRecord],
        ordinal: Int
    ) -> String {
        guard records[base] != nil else { return base }
        return "\(base):\(ordinal)"
    }

    private func permissionSubject(toolName: String?, toolInputJSON: String?) -> String {
        let tool = toolName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Tool"
        guard let toolInputJSON, !toolInputJSON.isEmpty else { return tool }
        if let data = toolInputJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["command", "cmd", "file_path", "path", "description", "query"] {
                if let value = object[key] as? String, !value.isEmpty {
                    return "\(tool): \(value)"
                }
            }
        }
        let compact = toolInputJSON.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return "\(tool): \(compact.count > 1_000 ? String(compact.prefix(1_000)) + "…" : compact)"
    }
}
