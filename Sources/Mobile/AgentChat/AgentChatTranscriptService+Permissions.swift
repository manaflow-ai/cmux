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
    func notePermissionRequest(
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
        let scope = permissionScope(from: event)
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
            options: ChatPermissionRequest.defaultOptions,
            scope: scope,
            resolution: nil
        )
        records[identity] = record
        permissionRecordsBySessionID[sessionID] = records
        guard chatEventsAreSubscribed else { return }
        emitChatFrame(ChatSessionEventFrame(sessionID: sessionID, event: .appended([record.message])))
    }

    /// OpenCode forms are delivered as blocking hook events rather than
    /// transcript rows. Preserve the first question as a native chat card so
    /// the phone can answer the same `feed.push` request the desktop UI uses.
    func noteQuestionRequest(
        _ event: WorkstreamEvent,
        sessionID: String,
        agentKind: ChatAgentKind
    ) {
        let rawRequestID = permissionRequestID(from: event)
        let answerKind: FeedAnswerKind = event.hookEventName == .exitPlanMode ? .exitPlan : .question
        let parsed = questionPayloads(toolInputJSON: event.toolInputJSON, answerKind: answerKind)
        let fingerprint = rawRequestID.map { "request:\($0)" }
            ?? "fingerprint:\(event.toolName ?? "question"):" + (event.toolInputJSON ?? "")
        var records = questionRecordsBySessionID[sessionID, default: [:]]
        guard !records.values.contains(where: {
            $0.selectedOptionLabels.isEmpty
                && ($0.requestFingerprint == fingerprint
                    || $0.identity == fingerprint
                    || (rawRequestID != nil && $0.rawRequestID == rawRequestID))
        }) else { return }
        let groupOrdinal = nextPermissionOrdinalBySessionID[sessionID, default: 0]
        let groupID = "\(fingerprint):group-\(groupOrdinal)"
        let questionCount = parsed.count
        var messages: [ChatMessage] = []
        for (questionIndex, question) in parsed.enumerated() {
            let ordinal = nextPermissionOrdinalBySessionID[sessionID, default: 0]
            nextPermissionOrdinalBySessionID[sessionID] = ordinal + 1
            let identity = "\(groupID):q\(questionIndex)"
            let record = QuestionRecord(
                identity: identity,
                groupID: groupID,
                requestFingerprint: fingerprint,
                questionIndex: questionIndex,
                questionCount: questionCount,
                questionID: question.id,
                rawRequestID: rawRequestID,
                messageID: "question:\(sessionID):\(identity)",
                seq: 1_000_000_000 + ordinal,
                timestamp: event.receivedAt,
                prompt: question.prompt,
                options: question.options,
                multiSelect: question.multiSelect,
                answerKind: answerKind,
                selectedOptionLabels: [],
                selectedOptionIDs: []
            )
            records[identity] = record
            messages.append(record.message)
        }
        questionRecordsBySessionID[sessionID] = records
        guard chatEventsAreSubscribed else { return }
        emitChatFrame(ChatSessionEventFrame(sessionID: sessionID, event: .appended(messages)))
        _ = agentKind
    }

    private struct ParsedQuestion {
        let id: String?
        let prompt: String
        let options: [ChatQuestion.Option]
        let multiSelect: Bool
    }

    private func questionPayloads(
        toolInputJSON: String?,
        answerKind: FeedAnswerKind
    ) -> [ParsedQuestion] {
        if case .exitPlan = answerKind {
            let input = toolInputJSON.flatMap { raw -> [String: Any]? in
                guard let data = raw.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            } ?? [:]
            let prompt = (input["question"] as? String)
                ?? (input["plan"] as? String)
                ?? "Review the plan before continuing"
            return [ParsedQuestion(
                id: nil,
                prompt: prompt,
                options: [ChatQuestion.Option(label: "Approve plan", id: "approve"), ChatQuestion.Option(label: "Reject plan", id: "reject")],
                multiSelect: false
            )]
        }
        return WorkstreamQuestionPrompt.parse(toolInputJSON: toolInputJSON).map { question in
            let options = question.options.map {
                ChatQuestion.Option(label: $0.label, detail: $0.description, id: $0.id)
            }
            return ParsedQuestion(
                id: question.id,
                prompt: question.prompt.isEmpty ? "The agent is waiting for an answer" : question.prompt,
                options: options.isEmpty ? [ChatQuestion.Option(label: "Continue", id: "continue")] : options,
                multiSelect: question.multiSelect
            )
        }
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
        updated.resolution = switch optionIndex {
        case 0: .approved
        case 1: .approvedAlways
        case 2: .approvedAll
        default: .denied
        }
        records[updated.identity] = updated
        permissionRecordsBySessionID[sessionID] = records
        if chatEventsAreSubscribed {
            emitChatFrame(ChatSessionEventFrame(sessionID: sessionID, event: .updated([updated.message])))
        }
        return true
    }

    @discardableResult
    func resolveQuestion(sessionID: String, messageID: String?, optionIndex: Int) -> Bool {
        guard let messageID,
              var records = questionRecordsBySessionID[sessionID],
              let key = records.first(where: { $0.value.messageID == messageID })?.key,
              var record = records[key],
              record.options.indices.contains(optionIndex) else { return false }
        if !record.multiSelect, let selected = record.selectedOptionLabels.first {
            return selected == record.options[optionIndex].label
        }
        let option = record.options[optionIndex]
        if record.multiSelect {
            guard !record.selectedOptionIDs.contains(option.id) else { return true }
            record.selectedOptionIDs.append(option.id)
            record.selectedOptionLabels.append(option.label)
        } else {
            record.selectedOptionIDs = [option.id]
            record.selectedOptionLabels = [option.label]
        }
        records[key] = record
        questionRecordsBySessionID[sessionID] = records
        if chatEventsAreSubscribed {
            emitChatFrame(ChatSessionEventFrame(sessionID: sessionID, event: .updated([record.message])))
        }
        return true
    }

    /// Returns whether a resolved question matches a repeated answer. nil
    /// means unknown or still pending; false means a conflicting option.
    func resolvedQuestionAnswer(
        sessionID: String,
        messageID: String,
        optionIndex: Int
    ) -> Bool? {
        guard let record = questionRecordsBySessionID[sessionID]?.values.first(where: {
            $0.messageID == messageID
        }), record.options.indices.contains(optionIndex),
              let selected = record.selectedOptionLabels.first else { return nil }
        return selected == record.options[optionIndex].label
    }

    /// Returns whether a synthetic question was already answered with the
    /// same free-form text. nil means the card is unknown or still pending.
    func resolvedQuestionText(
        sessionID: String,
        messageID: String,
        text: String
    ) -> Bool? {
        guard let record = questionRecordsBySessionID[sessionID]?.values.first(where: {
            $0.messageID == messageID
        }), !record.selectedOptionLabels.isEmpty else { return nil }
        return record.selectedOptionLabels == [text.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    @discardableResult
    func expireQuestionRequests(sessionID: String) -> Bool {
        guard var records = questionRecordsBySessionID[sessionID], !records.isEmpty else { return false }
        var updates: [ChatMessage] = []
        var didChange = false
        for (key, value) in records {
            guard value.selectedOptionLabels.isEmpty else { continue }
            var next = value
            next.selectedOptionLabels = ["Expired"]
            next.selectedOptionIDs = ["expired"]
            records[key] = next
            updates.append(next.message)
            didChange = true
        }
        guard didChange else { return false }
        questionRecordsBySessionID[sessionID] = records
        if chatEventsAreSubscribed {
            emitChatFrame(ChatSessionEventFrame(sessionID: sessionID, event: .updated(updates)))
        }
        return true
    }

    /// The producer request and decision shape for a synthesized card. The
    /// mobile message id is deliberately host-local; blocking hook producers
    /// need their original id to wake the `feed.push` waiter.
    struct FeedAnswerRequest {
        let requestID: String
        let kind: FeedAnswerKind
        let optionLabels: [String]
        let optionIDs: [String]
        let multiSelect: Bool
    }

    func feedAnswerRequest(sessionID: String, messageID: String) -> FeedAnswerRequest? {
        if let record = permissionRecordsBySessionID[sessionID]?.values.first(where: {
            $0.messageID == messageID
        }), let requestID = record.rawRequestID, !requestID.isEmpty {
            return FeedAnswerRequest(
                requestID: requestID,
                kind: .permission,
                optionLabels: record.options.map(\.label),
                optionIDs: record.options.map(\.id),
                multiSelect: false
            )
        }
        if let record = questionRecordsBySessionID[sessionID]?.values.first(where: {
            $0.messageID == messageID
        }), let requestID = record.rawRequestID, !requestID.isEmpty,
           record.selectedOptionLabels.isEmpty {
            return FeedAnswerRequest(
                requestID: requestID,
                kind: record.answerKind,
                optionLabels: record.options.map(\.label),
                optionIDs: record.options.map(\.id),
                multiSelect: record.multiSelect
            )
        }
        return nil
    }

    /// Builds the provider-native decision for a mobile card and marks the
    /// card resolved. The caller must deliver the returned decision to
    /// `FeedCoordinator`; keeping the lookup and local state transition here
    /// prevents the answer path from guessing which pending card was tapped.
    @discardableResult
    func feedAnswer(
        sessionID: String,
        messageID: String,
        optionIndex: Int
    ) -> (requestID: String, decision: WorkstreamDecision?)? {
        feedAnswer(
            sessionID: sessionID,
            messageID: messageID,
            optionIndexes: [optionIndex],
            text: nil
        )
    }

    /// Builds and records a provider-native answer for one or more selected
    /// options or a free-form response.
    @discardableResult
    func feedAnswer(
        sessionID: String,
        messageID: String,
        optionIndexes: [Int],
        text: String?
    ) -> (requestID: String, decision: WorkstreamDecision?)? {
        guard optionIndexes.allSatisfy({ $0 >= 0 }),
              let request = feedAnswerRequest(sessionID: sessionID, messageID: messageID) else {
            return nil
        }
        switch request.kind {
        case .permission:
            guard optionIndexes.count == 1, let optionIndex = optionIndexes.first else { return nil }
            guard request.optionLabels.indices.contains(optionIndex) else { return nil }
            let mode: WorkstreamPermissionMode
            switch optionIndex {
            case 0: mode = .once
            case 1: mode = .always
            case 2: mode = .all
            default: mode = .deny
            }
            let decision: WorkstreamDecision = .permission(mode)
            guard resolvePermission(
                sessionID: sessionID,
                requestID: messageID,
                optionIndex: optionIndex
            ) else { return nil }
            return (request.requestID, decision)
        case .question:
            guard let record = questionRecordsBySessionID[sessionID]?.values.first(where: {
                $0.messageID == messageID
            }) else { return nil }
            let indexes: [Int]
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard optionIndexes.isEmpty else { return nil }
                indexes = []
            } else {
                guard !optionIndexes.isEmpty,
                      request.optionLabels.indices.contains(optionIndexes[0]),
                      request.multiSelect || optionIndexes.count == 1,
                      Set(optionIndexes).count == optionIndexes.count,
                      optionIndexes.allSatisfy(request.optionLabels.indices.contains) else { return nil }
                indexes = optionIndexes
            }
            var updated = record
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.selectedOptionLabels = [answer]
                updated.selectedOptionIDs = [answer]
            } else {
                updated.selectedOptionLabels = indexes.map { updated.options[$0].label }
                updated.selectedOptionIDs = indexes.map { updated.options[$0].id }
            }
            guard let key = questionRecordsBySessionID[sessionID]?.first(where: {
                $0.value.messageID == messageID
            })?.key else { return nil }
            questionRecordsBySessionID[sessionID]?[key] = updated
            if chatEventsAreSubscribed {
                emitChatFrame(ChatSessionEventFrame(sessionID: sessionID, event: .updated([updated.message])))
            }
            let groupID = updated.groupID
            let group = questionRecordsBySessionID[sessionID, default: [:]].values
                .filter { $0.groupID == groupID }
                .sorted { $0.questionIndex < $1.questionIndex }
            guard group.allSatisfy({ !$0.selectedOptionLabels.isEmpty }) else {
                return (request.requestID, nil)
            }
            return (
                request.requestID,
                .question(selections: group.flatMap(\.selectedOptionLabels))
            )
        case .exitPlan:
            guard optionIndexes.count == 1, let optionIndex = optionIndexes.first else { return nil }
            guard request.optionLabels.indices.contains(optionIndex) else { return nil }
            let decision: WorkstreamDecision = .exitPlan(
                optionIndex == 0 ? .autoAccept : .deny,
                feedback: nil
            )
            guard resolveQuestion(
                sessionID: sessionID,
                messageID: messageID,
                optionIndex: optionIndex
            ) else { return nil }
            return (request.requestID, decision)
        }
    }

    /// Returns the producer request id for a synthesized permission card.
    /// Kept as a small compatibility helper for callers that only need the
    /// request identity.
    func feedRequestID(sessionID: String, messageID: String) -> String? {
        guard let request = feedAnswerRequest(sessionID: sessionID, messageID: messageID),
              request.kind == .permission else { return nil }
        return request.requestID
    }

    /// Expires cards when a turn/session stops without a mobile answer.
    @discardableResult
    func expirePermissionRequests(sessionID: String) -> Bool {
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

    func historyPageWithPermissions(
        _ page: ChatHistoryPage,
        sessionID: String,
        beforeSeq: Int?,
        limit: Int
    ) -> ChatHistoryPage {
        let permissions = permissionRecordsBySessionID[sessionID, default: [:]]
            .values
            .map(\.message)
        let questions = questionRecordsBySessionID[sessionID, default: [:]]
            .values
            .map(\.message)
        let merged = mergePermissionMessages(
            transcript: page.messages,
            permissions: Array(permissions) + questions,
            beforeSeq: beforeSeq,
            limit: limit
        )
        return ChatHistoryPage(
            messages: merged.messages,
            hasMore: page.hasMore || merged.hasMore,
            terminalBlocks: page.terminalBlocks,
            usage: page.usage
        )
    }

    func permissionOnlyHistory(
        sessionID: String,
        beforeSeq: Int?,
        limit: Int
    ) -> ChatHistoryPage? {
        guard permissionRecordsBySessionID[sessionID] != nil
            || questionRecordsBySessionID[sessionID] != nil else { return nil }
        let merged = mergePermissionMessages(
            transcript: [],
            permissions: permissionRecordsBySessionID[sessionID, default: [:]].values.map(\.message)
                + questionRecordsBySessionID[sessionID, default: [:]].values.map(\.message),
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
            .filter { message in
                guard let beforeSeq else { return true }
                return message.seq < beforeSeq
            }
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

    private func permissionScope(from event: WorkstreamEvent) -> String? {
        guard let raw = event.extraFieldsJSON,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return event.toolName }
        for key in ["pattern", "command_pattern", "scope", "tool_name"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return event.toolName
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
