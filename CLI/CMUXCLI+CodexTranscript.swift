import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - Codex transcript reading
extension CMUXCLI {
    struct CodexHookFailureSummary {
        let statusValue: String
        let subtitle: String
        let body: String
    }

    struct CodexHookFailureCandidate {
        let message: String
        let codexErrorInfo: String?
        let additionalDetails: String?
        let isStreamError: Bool
    }

    struct CodexHookUserInputCandidate {
        let callId: String
        let question: String?
    }

    struct CodexTranscriptSubagentSignals {
        var isSubagentSession = false
        var hasSubagentNotificationRelay = false
    }

    enum CodexTranscriptFailureReadResult {
        case unavailable
        case pending
        case healthy
        case failure(CodexHookFailureCandidate)
    }

    enum CodexMonitorOwnerState {
        case alive
        case gone
        case unknown
    }

    func summarizeCodexHookFailure(
        parsedInput: ClaudeHookParsedInput,
        sessionId: String,
        env: [String: String]
    ) -> CodexHookFailureSummary? {
        if let candidate = codexHookFailureCandidate(from: parsedInput.object) {
            return summarizeCodexHookFailureCandidate(candidate)
        }

        let payloadHasAssistantMessage = codexHookStopPayloadHasAssistantMessage(parsedInput.object)
        let providedTranscriptPath = normalizedHookValue(parsedInput.transcriptPath)
        var checkedTranscriptPaths: Set<String> = []
        let readTranscriptFailure: (String) -> CodexTranscriptFailureReadResult = { path in
            checkedTranscriptPaths.insert(path)
            return readCodexTranscriptFailure(
                path: path,
                turnId: parsedInput.turnId,
                requireTerminalCompletion: false
            )
        }

        if let transcriptPath = providedTranscriptPath
            ?? findCodexTranscriptPath(sessionId: sessionId, env: env) {
            switch readTranscriptFailure(transcriptPath) {
            case .failure(let failure):
                return summarizeCodexHookFailureCandidate(failure)
            case .healthy:
                return nil
            case .pending, .unavailable:
                break
            }
        }

        if providedTranscriptPath != nil,
           let resolvedTranscriptPath = findCodexTranscriptPath(sessionId: sessionId, env: env),
           !checkedTranscriptPaths.contains(resolvedTranscriptPath) {
            switch readTranscriptFailure(resolvedTranscriptPath) {
            case .failure(let failure):
                return summarizeCodexHookFailureCandidate(failure)
            case .healthy:
                return nil
            case .pending, .unavailable:
                break
            }
        }

        if payloadHasAssistantMessage {
            return nil
        }
        if let fallback = parsedInput.rawFallback, !fallback.isEmpty {
            return summarizeCodexHookFailureCandidate(
                CodexHookFailureCandidate(
                    message: fallback,
                    codexErrorInfo: nil,
                    additionalDetails: nil,
                    isStreamError: false
                )
            )
        }
        return nil
    }

    func readCodexTranscriptFailure(
        path: String,
        turnId: String? = nil,
        requireTerminalCompletion: Bool = false
    ) -> CodexTranscriptFailureReadResult {
        guard let lines = readRecentTextFileLines(path: path, maxBytes: 512 * 1024) else {
            return .unavailable
        }

        var candidate: CodexHookFailureCandidate?
        var candidateCanPublishBeforeTerminal = false
        var sawAssistantMessage = false
        var sawTerminalTurn = false
        var sawRelevantTurn = turnId == nil
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                continue
            }

            if (turnId == nil || sawRelevantTurn) && codexTranscriptLineHasAssistantMessage(object) {
                sawAssistantMessage = true
                candidate = nil
                candidateCanPublishBeforeTerminal = false
            }

            guard (object["type"] as? String) == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String else {
                continue
            }

            switch eventType {
            case "task_started":
                let payloadTurnId = firstString(in: payload, keys: ["turn_id", "turnId"])
                if let turnId {
                    guard payloadTurnId == turnId else {
                        continue
                    }
                }
                sawRelevantTurn = true
                candidate = nil
                candidateCanPublishBeforeTerminal = false
            case "error":
                let payloadTurnId = firstString(in: payload, keys: ["turn_id", "turnId"])
                if let turnId, let payloadTurnId {
                    guard payloadTurnId == turnId else {
                        continue
                    }
                    sawRelevantTurn = true
                }
                if let failure = codexHookFailureCandidate(
                    from: payload,
                    isStreamError: false,
                    requireFailureSignal: false
                ) {
                    candidate = failure
                    candidateCanPublishBeforeTerminal = turnId == nil || payloadTurnId == turnId || sawRelevantTurn
                }
            case "stream_error":
                let payloadTurnId = firstString(in: payload, keys: ["turn_id", "turnId"])
                if let turnId, let payloadTurnId {
                    guard payloadTurnId == turnId else {
                        continue
                    }
                    sawRelevantTurn = true
                }
                if let failure = codexHookFailureCandidate(
                    from: payload,
                    isStreamError: true,
                    requireFailureSignal: false
                ) {
                    candidate = failure
                    candidateCanPublishBeforeTerminal = turnId == nil || payloadTurnId == turnId || sawRelevantTurn
                }
            case "task_complete", "turn_complete":
                let payloadTurnId = firstString(in: payload, keys: ["turn_id", "turnId"])
                if let turnId {
                    guard payloadTurnId == turnId else {
                        continue
                    }
                }
                sawRelevantTurn = true
                sawTerminalTurn = true
                if let lastMessage = payload["last_agent_message"] as? String,
                   !lastMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sawAssistantMessage = true
                    candidate = nil
                    candidateCanPublishBeforeTerminal = false
                } else if candidate == nil && !sawAssistantMessage {
                    candidate = CodexHookFailureCandidate(
                        message: String(
                            localized: "agent.codex.error.noFinalResponse",
                            defaultValue: "Codex ended before sending a final response"
                        ),
                        codexErrorInfo: nil,
                        additionalDetails: nil,
                        isStreamError: false
                    )
                    candidateCanPublishBeforeTerminal = false
                }
            default:
                break
            }
        }

        if let candidate, candidateCanPublishBeforeTerminal {
            return .failure(candidate)
        }
        if candidate != nil, turnId != nil, !sawRelevantTurn {
            return .pending
        }
        if requireTerminalCompletion, !sawTerminalTurn {
            return .pending
        }
        if let candidate {
            return .failure(candidate)
        }
        if !sawTerminalTurn, !sawAssistantMessage {
            return .pending
        }
        return .healthy
    }

    func codexTranscriptTerminalTurnIds(path: String, turnIds: Set<String>) -> Set<String> {
        let expectedTurnIds = Set(turnIds.compactMap { normalizedHookValue($0) })
        guard !expectedTurnIds.isEmpty,
              let lines = readRecentTextFileLines(path: path, maxBytes: 512 * 1024) else {
            return []
        }

        var terminalTurnIds = Set<String>()
        var currentTurnId: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let objectType = object["type"] as? String else {
                continue
            }

            if objectType == "turn_context",
               let payload = object["payload"] as? [String: Any] {
                currentTurnId = firstString(in: payload, keys: ["turn_id", "turnId"])
                continue
            }

            guard objectType == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String else {
                continue
            }

            if eventType == "task_started" {
                currentTurnId = firstString(in: payload, keys: ["turn_id", "turnId"])
                continue
            }

            switch eventType {
            case "task_complete", "turn_complete", "turn_aborted":
                let payloadTurnId = firstString(in: payload, keys: ["turn_id", "turnId"]) ?? currentTurnId
                if let payloadTurnId, expectedTurnIds.contains(payloadTurnId) {
                    terminalTurnIds.insert(payloadTurnId)
                }
            default:
                break
            }
        }

        return terminalTurnIds
    }

    func readCodexTranscriptUserInput(
        path: String,
        turnId: String?,
        excluding publishedCallIds: Set<String>
    ) -> CodexHookUserInputCandidate? {
        guard let lines = readRecentTextFileLines(path: path, maxBytes: 512 * 1024) else {
            return nil
        }

        var sawRelevantTurn = turnId == nil
        var candidate: CodexHookUserInputCandidate?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let objectType = object["type"] as? String else {
                continue
            }

            if objectType == "turn_context",
               let payload = object["payload"] as? [String: Any] {
                let payloadTurnId = firstString(in: payload, keys: ["turn_id", "turnId"])
                if let turnId {
                    sawRelevantTurn = payloadTurnId == turnId
                } else {
                    sawRelevantTurn = true
                }
                continue
            }

            if objectType == "response_item",
               let payload = object["payload"] as? [String: Any],
               let userInput = codexUserInputFunctionCallCandidate(
                   from: payload,
                   turnId: turnId,
                   sawRelevantTurn: sawRelevantTurn,
                   excluding: publishedCallIds
               ) {
                candidate = userInput
                continue
            }

            guard objectType == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String else {
                continue
            }

            switch eventType {
            case "task_started":
                let payloadTurnId = firstString(in: payload, keys: ["turn_id", "turnId"])
                if let turnId {
                    sawRelevantTurn = payloadTurnId == turnId
                } else {
                    sawRelevantTurn = true
                }

            case "request_user_input":
                if let userInput = codexUserInputEventCandidate(
                    from: payload,
                    turnId: turnId,
                    sawRelevantTurn: sawRelevantTurn,
                    excluding: publishedCallIds
                ) {
                    candidate = userInput
                }

            case "task_complete", "turn_complete":
                let payloadTurnId = firstString(in: payload, keys: ["turn_id", "turnId"])
                if let turnId {
                    guard payloadTurnId == turnId else { continue }
                }
                sawRelevantTurn = true
                candidate = nil

            default:
                break
            }
        }

        return candidate
    }

    func readCodexTranscriptSubagentSignals(
        path: String,
        turnId: String?
    ) -> CodexTranscriptSubagentSignals {
        guard let lines = readRecentTextFileLines(path: path, maxBytes: 512 * 1024) else {
            return CodexTranscriptSubagentSignals()
        }

        let normalizedTurnId = normalizedHookValue(turnId)
        var signals = CodexTranscriptSubagentSignals()
        var currentTurnId: String?
        var currentTurnRelevant = normalizedTurnId == nil

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let objectType = object["type"] as? String else {
                continue
            }

            if objectType == "session_meta",
               let payload = object["payload"] as? [String: Any],
               codexTranscriptSessionMetaIsSubagent(payload) {
                signals.isSubagentSession = true
            }

            if objectType == "turn_context",
               let payload = object["payload"] as? [String: Any] {
                let payloadTurnId = firstString(in: payload, keys: ["turn_id", "turnId"])
                currentTurnId = payloadTurnId
                currentTurnRelevant = normalizedTurnId.map { $0 == payloadTurnId } ?? true
                continue
            }

            if objectType == "event_msg",
               let payload = object["payload"] as? [String: Any],
               let eventType = payload["type"] as? String {
                switch eventType {
                case "task_started":
                    let payloadTurnId = firstString(in: payload, keys: ["turn_id", "turnId"])
                    currentTurnId = payloadTurnId
                    currentTurnRelevant = normalizedTurnId.map { $0 == payloadTurnId } ?? true
                case "task_complete", "turn_complete":
                    let payloadTurnId = firstString(in: payload, keys: ["turn_id", "turnId"])
                    if let payloadTurnId {
                        currentTurnId = payloadTurnId
                    }
                    if let normalizedTurnId {
                        if payloadTurnId == normalizedTurnId || (payloadTurnId == nil && currentTurnRelevant) {
                            currentTurnRelevant = false
                        }
                    } else {
                        currentTurnRelevant = false
                    }
                default:
                    break
                }
                continue
            }

            guard currentTurnRelevant || currentTurnId == nil else {
                continue
            }
            guard codexTranscriptLineHasSubagentNotification(object) else {
                continue
            }
            signals.hasSubagentNotificationRelay = true
        }

        return signals
    }

    private func codexTranscriptSessionMetaIsSubagent(_ payload: [String: Any]) -> Bool {
        if firstString(in: payload, keys: ["thread_source", "threadSource"])?.lowercased() == "subagent" {
            return true
        }
        if let source = payload["source"] as? [String: Any],
           source["subagent"] != nil {
            return true
        }
        return false
    }

    private func codexTranscriptLineHasSubagentNotification(_ object: [String: Any]) -> Bool {
        guard (object["type"] as? String) == "response_item",
              let payload = object["payload"] as? [String: Any],
              (payload["type"] as? String) == "message",
              (payload["role"] as? String) == "user" else {
            return false
        }
        return codexTranscriptMessageText(payload)
            .map { $0.contains("<subagent_notification>") }
            ?? false
    }

    private func codexTranscriptMessageText(_ payload: [String: Any]) -> String? {
        if let content = payload["content"] as? String {
            let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
        guard let content = payload["content"] as? [[String: Any]] else {
            return nil
        }
        let parts = content.compactMap { block -> String? in
            let text = (block["text"] as? String) ?? (block["input_text"] as? String)
            let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized?.isEmpty == false ? normalized : nil
        }
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    private func codexUserInputEventCandidate(
        from payload: [String: Any],
        turnId: String?,
        sawRelevantTurn: Bool,
        excluding publishedCallIds: Set<String>
    ) -> CodexHookUserInputCandidate? {
        let payloadTurnId = firstString(in: payload, keys: ["turn_id", "turnId"])
        if let turnId {
            if let payloadTurnId {
                guard payloadTurnId == turnId else { return nil }
            } else {
                guard sawRelevantTurn else { return nil }
            }
        }
        return codexUserInputCandidate(
            from: payload,
            payloadTurnId: payloadTurnId,
            turnId: turnId,
            excluding: publishedCallIds
        )
    }

    private func codexUserInputFunctionCallCandidate(
        from payload: [String: Any],
        turnId: String?,
        sawRelevantTurn: Bool,
        excluding publishedCallIds: Set<String>
    ) -> CodexHookUserInputCandidate? {
        guard (payload["type"] as? String) == "function_call",
              (payload["name"] as? String) == "request_user_input" else {
            return nil
        }

        let arguments = codexFunctionCallArgumentsObject(from: payload)
        let payloadTurnId = firstString(in: payload, keys: ["turn_id", "turnId"])
            ?? arguments.flatMap { firstString(in: $0, keys: ["turn_id", "turnId"]) }
        if let turnId {
            if let payloadTurnId {
                guard payloadTurnId == turnId else { return nil }
            } else {
                guard sawRelevantTurn else { return nil }
            }
        }

        return codexUserInputCandidate(
            from: arguments ?? payload,
            payloadTurnId: payloadTurnId,
            turnId: turnId,
            fallbackCallId: firstString(in: payload, keys: ["call_id", "callId"]),
            excluding: publishedCallIds
        )
    }

    private func codexFunctionCallArgumentsObject(from payload: [String: Any]) -> [String: Any]? {
        if let arguments = payload["arguments"] as? [String: Any] {
            return arguments
        }
        guard let rawArguments = payload["arguments"] as? String,
              let data = rawArguments.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }
        return arguments
    }

    private func codexUserInputCandidate(
        from payload: [String: Any],
        payloadTurnId: String?,
        turnId: String?,
        fallbackCallId: String? = nil,
        excluding publishedCallIds: Set<String>
    ) -> CodexHookUserInputCandidate? {
        let question = codexUserInputQuestionText(from: payload)
        let rawCallId = firstString(in: payload, keys: ["call_id", "callId"]) ?? fallbackCallId
        let callId = rawCallId?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "\(payloadTurnId ?? turnId ?? "session"):\(question ?? "request_user_input")"
        guard !publishedCallIds.contains(callId) else { return nil }
        return CodexHookUserInputCandidate(callId: callId, question: question)
    }

    private func codexUserInputQuestionText(from payload: [String: Any]) -> String? {
        guard let questions = payload["questions"] as? [[String: Any]] else {
            return nil
        }
        for question in questions {
            let text = firstString(in: question, keys: ["question", "header", "id"])
            let normalized = text.map(normalizedSingleLine)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalized, !normalized.isEmpty {
                return truncate(normalized, maxLength: 220)
            }
        }
        return nil
    }

    private func codexHookStopPayloadHasAssistantMessage(_ object: [String: Any]?) -> Bool {
        guard let object,
              let message = firstString(in: object, keys: ["last_assistant_message", "lastAssistantMessage"]) else {
            return false
        }
        return !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func codexTranscriptLineHasAssistantMessage(_ object: [String: Any]) -> Bool {
        guard (object["type"] as? String) == "response_item",
              let payload = object["payload"] as? [String: Any],
              (payload["type"] as? String) == "message",
              (payload["role"] as? String) == "assistant",
              let content = payload["content"] as? [[String: Any]] else {
            return false
        }
        return content.contains { block in
            guard let text = block["text"] as? String else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func codexHookFailureCandidate(
        from object: [String: Any]?,
        isStreamError: Bool = false,
        requireFailureSignal: Bool = true
    ) -> CodexHookFailureCandidate? {
        guard let object else { return nil }
        let message = firstString(in: object, keys: ["message", "error", "body", "text", "description"])
        let additionalDetails = codexHookStringValue(object["additional_details"] ?? object["additionalDetails"])
        let codexErrorInfo = codexHookStringValue(object["codex_error_info"] ?? object["codexErrorInfo"])
        let eventType = firstString(in: object, keys: ["type", "kind"])?.lowercased()
        let typedFailure = eventType == "error" || eventType == "stream_error"
        let hasExplicitErrorField = object["error"].map { !($0 is NSNull) } ?? false
        let signal = [message, additionalDetails, codexErrorInfo]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        guard !requireFailureSignal ||
              typedFailure ||
              hasExplicitErrorField ||
              codexErrorInfo != nil ||
              signal.contains("error") ||
              signal.contains("failed") ||
              signal.contains("exception") ||
              signal.contains("usage limit") ||
              signal.contains("rate limit") ||
              signal.contains("stream disconnected") ||
              signal.contains("connection") ||
              signal.contains("unauthorized") else {
            return nil
        }
        return CodexHookFailureCandidate(
            message: message ?? additionalDetails ?? codexErrorInfo ?? String(
                localized: "agent.codex.error.defaultMessage",
                defaultValue: "Codex reported an error"
            ),
            codexErrorInfo: codexErrorInfo,
            additionalDetails: additionalDetails,
            isStreamError: isStreamError || eventType == "stream_error"
        )
    }

    func summarizeCodexHookFailureCandidate(_ candidate: CodexHookFailureCandidate) -> CodexHookFailureSummary {
        let signal = [
            candidate.message,
            candidate.codexErrorInfo,
            candidate.additionalDetails,
            candidate.isStreamError ? "stream_error" : nil
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        let subtitle: String
        let statusValue: String
        if signal.contains("usage_limit") ||
            signal.contains("usage limit") ||
            signal.contains("rate_limit") ||
            signal.contains("rate limit") ||
            signal.contains("credits") {
            subtitle = String(localized: "agent.codex.error.subtitle.rateLimit", defaultValue: "Rate limit")
            statusValue = String(localized: "agent.codex.error.status.rateLimit", defaultValue: "Codex rate limit")
        } else if signal.contains("unauthorized") ||
                    signal.contains("auth") ||
                    signal.contains("access token") ||
                    signal.contains("sign in") ||
                    signal.contains("login") {
            subtitle = String(localized: "agent.codex.error.subtitle.auth", defaultValue: "Auth error")
            statusValue = String(localized: "agent.codex.error.status.auth", defaultValue: "Codex auth error")
        } else if signal.contains("response_stream") ||
                    signal.contains("stream disconnected") ||
                    signal.contains("connection") ||
                    signal.contains("network") ||
                    signal.contains("offline") ||
                    signal.contains("timed out") ||
                    signal.contains("timeout") {
            subtitle = String(localized: "agent.codex.error.subtitle.network", defaultValue: "Network error")
            statusValue = String(localized: "agent.codex.error.status.network", defaultValue: "Codex network error")
        } else {
            subtitle = String(localized: "agent.codex.error.subtitle.generic", defaultValue: "Error")
            statusValue = String(localized: "agent.codex.error.status.generic", defaultValue: "Codex error")
        }

        let detail = candidate.additionalDetails ?? candidate.message
        return CodexHookFailureSummary(
            statusValue: statusValue,
            subtitle: subtitle,
            body: truncate(normalizedSingleLine(detail), maxLength: 220)
        )
    }

    private func codexHookStringValue(_ rawValue: Any?) -> String? {
        if let string = rawValue as? String {
            let trimmed = normalizedSingleLine(string)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let rawValue,
              JSONSerialization.isValidJSONObject(rawValue),
              let data = try? JSONSerialization.data(withJSONObject: rawValue, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = normalizedSingleLine(string)
        return trimmed.isEmpty ? nil : trimmed
    }

    func findCodexTranscriptPath(sessionId: String, env: [String: String]) -> String? {
        let normalizedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionId.isEmpty else { return nil }

        let codexHome = normalizedHookValue(env["CODEX_HOME"]) ?? "~/.codex"
        let sessionsURL = URL(fileURLWithPath: NSString(string: codexHome).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let fileManager = FileManager.default
        var newest: URL?
        var newestModificationDate: Date?
        for directoryURL in recentCodexSessionDirectories(sessionsURL: sessionsURL, fileManager: fileManager) {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for url in urls {
                guard url.pathExtension == "jsonl",
                      url.lastPathComponent.contains(normalizedSessionId) else {
                    continue
                }
                let modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if newest == nil || modificationDate > (newestModificationDate ?? .distantPast) {
                    newest = url
                    newestModificationDate = modificationDate
                }
            }
        }
        return newest?.path
    }

    private func recentCodexSessionDirectories(sessionsURL: URL, fileManager: FileManager) -> [URL] {
        var directories: [URL] = []
        var seenPaths = Set<String>()

        func appendIfDirectory(_ url: URL) {
            guard seenPaths.insert(url.path).inserted else { return }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return
            }
            directories.append(url)
        }

        appendIfDirectory(sessionsURL)

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        for calendar in [Calendar.current, utcCalendar] {
            for dayOffset in -14...1 {
                guard let date = calendar.date(byAdding: .day, value: dayOffset, to: Date()) else {
                    continue
                }
                let components = calendar.dateComponents([.year, .month, .day], from: date)
                guard let year = components.year,
                      let month = components.month,
                      let day = components.day else {
                    continue
                }
                appendIfDirectory(
                    sessionsURL
                        .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                        .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                        .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
                )
            }
        }

        return directories
    }

}
