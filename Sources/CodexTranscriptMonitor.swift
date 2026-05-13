import Darwin
import Foundation

struct CodexTranscriptMonitorRequest: Sendable {
    let workspaceId: UUID
    let surfaceId: UUID?
    let sessionId: String
    let turnId: String?
    let transcriptPath: String?
    let codexHome: String?
}

struct CodexTranscriptFailureSummary: Sendable {
    let statusValue: String
    let subtitle: String
    let body: String
}

enum CodexTranscriptMonitorEvent: Sendable {
    case userInput(request: CodexTranscriptMonitorRequest, body: String)
    case failure(request: CodexTranscriptMonitorRequest, summary: CodexTranscriptFailureSummary)
    case completion(request: CodexTranscriptMonitorRequest)
}

// Mutable registry state is confined to `queue`; callers interact through async queue hops.
final class CodexTranscriptMonitorRegistry: @unchecked Sendable {
    static let shared = CodexTranscriptMonitorRegistry()

    private let queue = DispatchQueue(label: "com.cmux.codex-transcript-monitor", qos: .utility)
    private var monitorsBySessionId: [String: Monitor] = [:]

    private init() {}

    deinit {}

    func start(_ request: CodexTranscriptMonitorRequest) {
        queue.async { [weak self] in
            guard let self else { return }
            let key = request.sessionId
            self.monitorsBySessionId[key]?.cancel()
            let monitor = Monitor(
                request: request,
                queue: self.queue,
                onEvent: { [weak self] event in self?.publish(event) },
                onFinish: { [weak self] sessionId, monitor in
                    guard let self else { return }
                    if self.monitorsBySessionId[sessionId] === monitor {
                        self.monitorsBySessionId.removeValue(forKey: sessionId)
                    }
                }
            )
            self.monitorsBySessionId[key] = monitor
            monitor.start()
        }
    }

    func stop(sessionId: String, turnId: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            if let monitor = self.monitorsBySessionId[sessionId],
               turnId == nil || monitor.matches(turnId: turnId) {
                monitor.cancel()
                self.monitorsBySessionId.removeValue(forKey: sessionId)
            }
        }
    }

    func stopWorkspace(_ workspaceId: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            let matchingSessionIds = self.monitorsBySessionId.compactMap { sessionId, monitor in
                monitor.workspaceId == workspaceId ? sessionId : nil
            }
            for sessionId in matchingSessionIds {
                self.monitorsBySessionId[sessionId]?.cancel()
                self.monitorsBySessionId.removeValue(forKey: sessionId)
            }
        }
    }

    private func publish(_ event: CodexTranscriptMonitorEvent) {
        Task { @MainActor in
            TerminalController.shared.handleCodexTranscriptMonitorEvent(event)
        }
    }

    private final class Monitor {
        private struct FailureCandidate {
            let message: String
            let codexErrorInfo: String?
            let additionalDetails: String?
            let isStreamError: Bool
        }

        private struct UserInputCandidate {
            let callId: String
            let question: String?
        }

        private enum Policy {
            static let maxTailBytes: UInt64 = 512 * 1024
            static let retryInterval: TimeInterval = 1
            static let deadline: TimeInterval = 4 * 60 * 60
        }

        let workspaceId: UUID

        private let request: CodexTranscriptMonitorRequest
        private let queue: DispatchQueue
        private let onEvent: (CodexTranscriptMonitorEvent) -> Void
        private let onFinish: (String, Monitor) -> Void
        private var source: DispatchSourceFileSystemObject?
        private var retryTimer: DispatchSourceTimer?
        private var deadlineTimer: DispatchSourceTimer?
        private var transcriptPath: String?
        private var readOffset: UInt64 = 0
        private var pendingData = Data()
        private var publishedUserInputCallIds = Set<String>()
        private var sawRelevantTurn = false
        private var sawAssistantMessage = false
        private var finished = false

        init(
            request: CodexTranscriptMonitorRequest,
            queue: DispatchQueue,
            onEvent: @escaping (CodexTranscriptMonitorEvent) -> Void,
            onFinish: @escaping (String, Monitor) -> Void
        ) {
            self.request = request
            self.queue = queue
            self.onEvent = onEvent
            self.onFinish = onFinish
            self.workspaceId = request.workspaceId
            self.transcriptPath = Self.normalizedValue(request.transcriptPath)
            self.sawRelevantTurn = Self.normalizedValue(request.turnId) == nil
        }

        deinit {
            cancel()
        }

        func start() {
            armDeadline()
            installSourceOrRetry()
        }

        func matches(turnId: String?) -> Bool {
            guard let turnId = Self.normalizedValue(turnId) else { return true }
            return Self.normalizedValue(request.turnId) == turnId
        }

        func cancel() {
            finished = true
            source?.cancel()
            source = nil
            retryTimer?.cancel()
            retryTimer = nil
            deadlineTimer?.cancel()
            deadlineTimer = nil
        }

        private func finish(publishCompletion: Bool = false) {
            guard !finished else { return }
            if publishCompletion {
                onEvent(.completion(request: request))
            }
            cancel()
            onFinish(request.sessionId, self)
        }

        private func armDeadline() {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Policy.deadline)
            timer.setEventHandler { [weak self] in
                self?.finish(publishCompletion: true)
            }
            timer.resume()
            deadlineTimer = timer
        }

        private func installSourceOrRetry() {
            guard !finished else { return }
            if transcriptPath == nil {
                transcriptPath = findTranscriptPath()
            }
            guard let path = transcriptPath else {
                scheduleRetry()
                return
            }
            installFileSource(path: path)
        }

        private func installFileSource(path: String) {
            source?.cancel()
            source = nil

            let expandedPath = NSString(string: path).expandingTildeInPath
            let fd = open(expandedPath, O_EVTONLY)
            guard fd >= 0 else {
                transcriptPath = nil
                scheduleRetry()
                return
            }

            let newSource = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .delete, .rename],
                queue: queue
            )
            newSource.setEventHandler { [weak self] in
                self?.handleFileEvent()
            }
            newSource.setCancelHandler {
                close(fd)
            }
            source = newSource
            newSource.resume()
            readInitialTail(path: expandedPath)
        }

        private func handleFileEvent() {
            guard !finished, let path = transcriptPath else { return }
            let expandedPath = NSString(string: path).expandingTildeInPath
            if let eventData = source?.data,
               eventData.contains(.delete) || eventData.contains(.rename) {
                source?.cancel()
                source = nil
                transcriptPath = nil
                readOffset = 0
                pendingData.removeAll(keepingCapacity: false)
                scheduleRetry()
                return
            }
            readIncremental(path: expandedPath)
        }

        private func scheduleRetry() {
            retryTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Policy.retryInterval)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.retryTimer?.cancel()
                self.retryTimer = nil
                self.installSourceOrRetry()
            }
            timer.resume()
            retryTimer = timer
        }

        private func readInitialTail(path: String) {
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return }
            defer { try? handle.close() }
            let endOffset = (try? handle.seekToEnd()) ?? 0
            let startOffset = endOffset > Policy.maxTailBytes ? endOffset - Policy.maxTailBytes : 0
            do {
                try handle.seek(toOffset: startOffset)
            } catch {
                readOffset = endOffset
                return
            }
            var data = handle.readDataToEndOfFile()
            if startOffset > 0, let newline = data.firstIndex(of: 0x0A) {
                data.removeSubrange(0...newline)
            }
            readOffset = endOffset
            process(data: data)
        }

        private func readIncremental(path: String) {
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
                transcriptPath = nil
                scheduleRetry()
                return
            }
            defer { try? handle.close() }
            let endOffset = (try? handle.seekToEnd()) ?? 0
            if readOffset > endOffset {
                readOffset = 0
                pendingData.removeAll(keepingCapacity: false)
            }
            do {
                try handle.seek(toOffset: readOffset)
            } catch {
                readOffset = endOffset
                return
            }
            let data = handle.readDataToEndOfFile()
            readOffset = endOffset
            process(data: data)
        }

        private func process(data: Data) {
            guard !data.isEmpty else { return }
            pendingData.append(data)
            while let newline = pendingData.firstIndex(of: 0x0A) {
                let lineData = pendingData[..<newline]
                pendingData.removeSubrange(pendingData.startIndex...newline)
                processLine(Data(lineData))
                if finished { return }
            }
        }

        private func processLine(_ lineData: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: lineData, options: []) as? [String: Any],
                  let objectType = object["type"] as? String else {
                return
            }

            if objectType == "turn_context",
               let payload = object["payload"] as? [String: Any] {
                updateRelevantTurn(payload: payload)
                return
            }

            if objectType == "response_item",
               let payload = object["payload"] as? [String: Any] {
                if transcriptLineHasAssistantMessage(payload: payload) {
                    sawAssistantMessage = true
                }
                if let userInput = userInputFunctionCallCandidate(from: payload) {
                    publishUserInput(userInput)
                }
                return
            }

            guard objectType == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String else {
                return
            }

            switch eventType {
            case "task_started":
                updateRelevantTurn(payload: payload)
                sawAssistantMessage = false

            case "request_user_input":
                if let userInput = userInputEventCandidate(from: payload) {
                    publishUserInput(userInput)
                }

            case "error", "stream_error":
                updateRelevantTurn(payload: payload, onlyWhenMatching: true)
                guard turnMatches(payload: payload) || sawRelevantTurn else { return }
                if let failure = Self.failureCandidate(
                    from: payload,
                    isStreamError: eventType == "stream_error",
                    requireFailureSignal: false
                ) {
                    publishFailure(failure)
                    finish()
                }

            case "task_complete", "turn_complete":
                guard turnMatches(payload: payload) || Self.normalizedValue(request.turnId) == nil else { return }
                sawRelevantTurn = true
                if let lastMessage = payload["last_agent_message"] as? String,
                   !lastMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sawAssistantMessage = true
                    finish(publishCompletion: true)
                } else if !sawAssistantMessage {
                    publishFailure(
                        FailureCandidate(
                            message: String(
                                localized: "agent.codex.error.noFinalResponse",
                                defaultValue: "Codex ended before sending a final response"
                            ),
                            codexErrorInfo: nil,
                            additionalDetails: nil,
                            isStreamError: false
                        )
                    )
                    finish()
                } else {
                    finish(publishCompletion: true)
                }

            default:
                break
            }
        }

        private func updateRelevantTurn(payload: [String: Any], onlyWhenMatching: Bool = false) {
            guard let requestTurnId = Self.normalizedValue(request.turnId) else {
                sawRelevantTurn = true
                return
            }
            guard let payloadTurnId = Self.firstString(in: payload, keys: ["turn_id", "turnId"]) else {
                if !onlyWhenMatching {
                    sawRelevantTurn = false
                }
                return
            }
            sawRelevantTurn = payloadTurnId == requestTurnId
        }

        private func turnMatches(payload: [String: Any]) -> Bool {
            guard let requestTurnId = Self.normalizedValue(request.turnId) else { return true }
            return Self.firstString(in: payload, keys: ["turn_id", "turnId"]) == requestTurnId
        }

        private func userInputEventCandidate(from payload: [String: Any]) -> UserInputCandidate? {
            guard turnMatches(payload: payload) || sawRelevantTurn else { return nil }
            return userInputCandidate(from: payload, payloadTurnId: Self.firstString(in: payload, keys: ["turn_id", "turnId"]))
        }

        private func userInputFunctionCallCandidate(from payload: [String: Any]) -> UserInputCandidate? {
            guard (payload["type"] as? String) == "function_call",
                  (payload["name"] as? String) == "request_user_input" else {
                return nil
            }
            let arguments = Self.codexFunctionCallArgumentsObject(from: payload)
            let payloadTurnId = Self.firstString(in: payload, keys: ["turn_id", "turnId"])
                ?? arguments.flatMap { Self.firstString(in: $0, keys: ["turn_id", "turnId"]) }
            if let requestTurnId = Self.normalizedValue(request.turnId) {
                if let payloadTurnId {
                    guard payloadTurnId == requestTurnId else { return nil }
                } else {
                    guard sawRelevantTurn else { return nil }
                }
            }
            return userInputCandidate(
                from: arguments ?? payload,
                payloadTurnId: payloadTurnId,
                fallbackCallId: Self.firstString(in: payload, keys: ["call_id", "callId"])
            )
        }

        private func userInputCandidate(
            from payload: [String: Any],
            payloadTurnId: String?,
            fallbackCallId: String? = nil
        ) -> UserInputCandidate? {
            let question = Self.userInputQuestionText(from: payload)
            let requestTurnId = Self.normalizedValue(request.turnId)
            let rawCallId = Self.firstString(in: payload, keys: ["call_id", "callId"]) ?? fallbackCallId
            let callId = rawCallId?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "\(payloadTurnId ?? requestTurnId ?? "session"):\(question ?? "request_user_input")"
            guard !publishedUserInputCallIds.contains(callId) else { return nil }
            return UserInputCandidate(callId: callId, question: question)
        }

        private func publishUserInput(_ userInput: UserInputCandidate) {
            publishedUserInputCallIds.insert(userInput.callId)
            let body = userInput.question ?? String(
                localized: "agent.codex.input.body.needsInput",
                defaultValue: "Codex is asking a question"
            )
            onEvent(.userInput(request: request, body: body))
        }

        private func publishFailure(_ failure: FailureCandidate) {
            onEvent(.failure(request: request, summary: Self.summarizeFailure(failure)))
        }

        private func transcriptLineHasAssistantMessage(payload: [String: Any]) -> Bool {
            guard (payload["type"] as? String) == "message",
                  (payload["role"] as? String) == "assistant",
                  let content = payload["content"] as? [[String: Any]] else {
                return false
            }
            return content.contains { block in
                guard let text = block["text"] as? String else { return false }
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }

        private func findTranscriptPath() -> String? {
            let normalizedSessionId = request.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedSessionId.isEmpty else { return nil }
            let codexHome = Self.normalizedValue(request.codexHome) ?? "~/.codex"
            let sessionsURL = URL(fileURLWithPath: NSString(string: codexHome).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
            let fileManager = FileManager.default
            var newest: URL?
            var newestModificationDate: Date?
            for directoryURL in Self.recentSessionDirectories(sessionsURL: sessionsURL, fileManager: fileManager) {
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

        private static func recentSessionDirectories(sessionsURL: URL, fileManager: FileManager) -> [URL] {
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
                    guard let date = calendar.date(byAdding: .day, value: dayOffset, to: Date.now) else { continue }
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

        private static func failureCandidate(
            from object: [String: Any],
            isStreamError: Bool,
            requireFailureSignal: Bool = true
        ) -> FailureCandidate? {
            let message = firstString(in: object, keys: ["message", "error", "body", "text", "description"])
            let additionalDetails = hookStringValue(object["additional_details"] ?? object["additionalDetails"])
            let codexErrorInfo = hookStringValue(object["codex_error_info"] ?? object["codexErrorInfo"])
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
            return FailureCandidate(
                message: message ?? additionalDetails ?? codexErrorInfo ?? String(
                    localized: "agent.codex.error.defaultMessage",
                    defaultValue: "Codex reported an error"
                ),
                codexErrorInfo: codexErrorInfo,
                additionalDetails: additionalDetails,
                isStreamError: isStreamError || eventType == "stream_error"
            )
        }

        private static func summarizeFailure(_ candidate: FailureCandidate) -> CodexTranscriptFailureSummary {
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
                signal.contains("rate limit") ||
                signal.contains("quota") {
                subtitle = String(localized: "agent.codex.error.subtitle.rateLimit", defaultValue: "Rate limit")
                statusValue = String(localized: "agent.codex.error.status.rateLimit", defaultValue: "Codex rate limit")
            } else if signal.contains("unauthorized") ||
                        signal.contains("auth") ||
                        signal.contains("login") ||
                        signal.contains("api key") {
                subtitle = String(localized: "agent.codex.error.subtitle.auth", defaultValue: "Auth error")
                statusValue = String(localized: "agent.codex.error.status.auth", defaultValue: "Codex auth error")
            } else if candidate.isStreamError ||
                        signal.contains("network") ||
                        signal.contains("connection") ||
                        signal.contains("stream disconnected") ||
                        signal.contains("timed out") {
                subtitle = String(localized: "agent.codex.error.subtitle.network", defaultValue: "Network error")
                statusValue = String(localized: "agent.codex.error.status.network", defaultValue: "Codex network error")
            } else {
                subtitle = String(localized: "agent.codex.error.subtitle.generic", defaultValue: "Error")
                statusValue = String(localized: "agent.codex.error.status.generic", defaultValue: "Codex error")
            }

            let detail = [candidate.message, candidate.codexErrorInfo, candidate.additionalDetails]
                .compactMap { normalizedValue($0).map(normalizedSingleLine) }
                .first { !$0.isEmpty } ?? candidate.message
            return CodexTranscriptFailureSummary(
                statusValue: statusValue,
                subtitle: subtitle,
                body: truncate(detail, maxLength: 220)
            )
        }

        private static func codexFunctionCallArgumentsObject(from payload: [String: Any]) -> [String: Any]? {
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

        private static func userInputQuestionText(from payload: [String: Any]) -> String? {
            let questions = payload["questions"] as? [[String: Any]] ?? []
            for question in questions {
                let text = firstString(in: question, keys: ["question", "header", "id"])
                let normalized = text.map(normalizedSingleLine)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let normalized, !normalized.isEmpty {
                    return truncate(normalized, maxLength: 220)
                }
            }
            return nil
        }

        private static func hookStringValue(_ rawValue: Any?) -> String? {
            guard let rawValue else { return nil }
            if rawValue is NSNull { return nil }
            if let value = rawValue as? String {
                return normalizedValue(value)
            }
            if let array = rawValue as? [Any] {
                let joined = array.compactMap(hookStringValue).joined(separator: " ")
                return normalizedValue(joined)
            }
            if let dict = rawValue as? [String: Any] {
                let joined = dict.keys.sorted().compactMap { hookStringValue(dict[$0]) }.joined(separator: " ")
                return normalizedValue(joined)
            }
            return normalizedValue(String(describing: rawValue))
        }

        private static func firstString(in object: [String: Any], keys: [String]) -> String? {
            for key in keys {
                if let value = hookStringValue(object[key]) {
                    return value
                }
            }
            return nil
        }

        private static func normalizedValue(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }

        private static func normalizedSingleLine(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        private static func truncate(_ value: String, maxLength: Int) -> String {
            guard value.count > maxLength else { return value }
            return String(value.prefix(maxLength - 3)) + "..."
        }
    }
}
