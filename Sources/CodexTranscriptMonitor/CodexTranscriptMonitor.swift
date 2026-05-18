import Darwin
import Foundation

final class CodexTranscriptMonitorSession {
    private enum Policy {
        static let maxTailBytes: UInt64 = 512 * 1024
        static let maxBufferedLineBytes = 1 * 1024 * 1024
        static let retryInterval: TimeInterval = 1
        static let deadline: TimeInterval = 4 * 60 * 60
    }

    let workspaceId: UUID

    private let request: CodexTranscriptMonitorRequest
    private let queue: DispatchQueue
    private let onEvent: (CodexTranscriptMonitorEvent) -> Void
    private let onFinish: (String, CodexTranscriptMonitorSession) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var retryTimer: DispatchSourceTimer?
    private var deadlineTimer: DispatchSourceTimer?
    private var transcriptPath: String?
    private var readOffset: UInt64 = 0
    private var pendingData = Data()
    private var discardingOversizedLine = false
    private var publishedUserInputCallIds = Set<String>()
    private var sawRelevantTurn = false
    private var sawAssistantMessage = false
    private var finished = false

    init(
        request: CodexTranscriptMonitorRequest,
        queue: DispatchQueue,
        onEvent: @escaping (CodexTranscriptMonitorEvent) -> Void,
        onFinish: @escaping (String, CodexTranscriptMonitorSession) -> Void
    ) {
        self.request = request
        self.queue = queue
        self.onEvent = onEvent
        self.onFinish = onFinish
        self.workspaceId = request.workspaceId
        self.transcriptPath = CodexTranscriptMonitorParser.normalizedValue(request.transcriptPath)
        self.sawRelevantTurn = CodexTranscriptMonitorParser.normalizedValue(request.turnId) == nil
    }

    deinit {
        cancel()
    }

    func start() {
        armDeadline()
        installSourceOrRetry()
    }

    func matches(turnId: String?) -> Bool {
        guard let turnId = CodexTranscriptMonitorParser.normalizedValue(turnId) else { return true }
        return CodexTranscriptMonitorParser.normalizedValue(request.turnId) == turnId
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
            resetTailState()
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
            resetTailState()
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
        let bytesRead = UInt64(data.count)
        if startOffset > 0, let newline = data.firstIndex(of: 0x0A) {
            data.removeSubrange(0...newline)
        }
        process(data: data)
        readOffset = startOffset + bytesRead
    }

    private func readIncremental(path: String) {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            transcriptPath = nil
            resetTailState()
            scheduleRetry()
            return
        }
        defer { try? handle.close() }
        let endOffset = (try? handle.seekToEnd()) ?? 0
        if readOffset > endOffset {
            resetTailState()
        }
        let seekOffset = readOffset
        do {
            try handle.seek(toOffset: seekOffset)
        } catch {
            readOffset = endOffset
            return
        }
        let data = handle.readDataToEndOfFile()
        process(data: data)
        readOffset = seekOffset + UInt64(data.count)
    }

    private func process(data: Data) {
        guard !data.isEmpty else { return }
        var cursor = data.startIndex
        while cursor < data.endIndex {
            if discardingOversizedLine {
                guard let newline = data[cursor...].firstIndex(of: 0x0A) else { return }
                discardingOversizedLine = false
                cursor = data.index(after: newline)
                continue
            }

            guard let newline = data[cursor...].firstIndex(of: 0x0A) else {
                if !appendPendingLineFragment(data[cursor...]) {
                    discardingOversizedLine = true
                }
                return
            }

            let lineData = data[cursor..<newline]
            if pendingData.isEmpty {
                if lineData.count <= Policy.maxBufferedLineBytes {
                    processLine(Data(lineData))
                }
            } else if appendPendingLineFragment(lineData) {
                let completeLine = pendingData
                pendingData.removeAll(keepingCapacity: true)
                processLine(completeLine)
            }
            if finished { return }
            cursor = data.index(after: newline)
        }
    }

    private func appendPendingLineFragment(_ fragment: Data.SubSequence) -> Bool {
        guard !fragment.isEmpty else { return true }
        guard pendingData.count + fragment.count <= Policy.maxBufferedLineBytes else {
            pendingData.removeAll(keepingCapacity: false)
            return false
        }
        pendingData.append(contentsOf: fragment)
        return true
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
            if CodexTranscriptMonitorParser.transcriptLineHasAssistantMessage(payload: payload),
               turnMatches(payload: payload) || sawRelevantTurn {
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
            if updateRelevantTurn(payload: payload) {
                sawAssistantMessage = false
            }

        case "request_user_input":
            if let userInput = userInputEventCandidate(from: payload) {
                publishUserInput(userInput)
            }

        case "error", "stream_error":
            updateRelevantTurn(payload: payload, onlyWhenMatching: true)
            guard turnMatches(payload: payload) || sawRelevantTurn else { return }
            if let failure = CodexTranscriptMonitorParser.failureCandidate(
                from: payload,
                isStreamError: eventType == "stream_error",
                requireFailureSignal: false
            ) {
                publishFailure(failure)
                finish()
            }

        case "task_complete", "turn_complete":
            guard turnMatches(payload: payload) else { return }
            sawRelevantTurn = true
            if let lastMessage = payload["last_agent_message"] as? String,
               !lastMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sawAssistantMessage = true
                finish(publishCompletion: true)
            } else if !sawAssistantMessage {
                publishFailure(
                    CodexTranscriptFailureCandidate(
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

    @discardableResult
    private func updateRelevantTurn(payload: [String: Any], onlyWhenMatching: Bool = false) -> Bool {
        guard let requestTurnId = CodexTranscriptMonitorParser.normalizedValue(request.turnId) else {
            sawRelevantTurn = true
            return true
        }
        guard let payloadTurnId = CodexTranscriptMonitorParser.firstString(in: payload, keys: ["turn_id", "turnId"]) else {
            return false
        }
        let matches = payloadTurnId == requestTurnId
        if matches || !onlyWhenMatching {
            sawRelevantTurn = matches
        }
        return matches
    }

    private func turnMatches(payload: [String: Any]) -> Bool {
        guard let requestTurnId = CodexTranscriptMonitorParser.normalizedValue(request.turnId) else { return true }
        return CodexTranscriptMonitorParser.firstString(in: payload, keys: ["turn_id", "turnId"]) == requestTurnId
    }

    private func userInputEventCandidate(from payload: [String: Any]) -> CodexTranscriptUserInputCandidate? {
        guard turnMatches(payload: payload) || sawRelevantTurn else { return nil }
        return userInputCandidate(
            from: payload,
            payloadTurnId: CodexTranscriptMonitorParser.firstString(in: payload, keys: ["turn_id", "turnId"])
        )
    }

    private func userInputFunctionCallCandidate(from payload: [String: Any]) -> CodexTranscriptUserInputCandidate? {
        guard (payload["type"] as? String) == "function_call",
              (payload["name"] as? String) == "request_user_input" else {
            return nil
        }
        let arguments = CodexTranscriptMonitorParser.codexFunctionCallArgumentsObject(from: payload)
        let payloadTurnId = CodexTranscriptMonitorParser.firstString(in: payload, keys: ["turn_id", "turnId"])
            ?? arguments.flatMap { CodexTranscriptMonitorParser.firstString(in: $0, keys: ["turn_id", "turnId"]) }
        if let requestTurnId = CodexTranscriptMonitorParser.normalizedValue(request.turnId) {
            if let payloadTurnId {
                guard payloadTurnId == requestTurnId else { return nil }
            } else {
                guard sawRelevantTurn else { return nil }
            }
        }
        return userInputCandidate(
            from: arguments ?? payload,
            payloadTurnId: payloadTurnId,
            fallbackCallId: CodexTranscriptMonitorParser.firstString(in: payload, keys: ["call_id", "callId"])
        )
    }

    private func userInputCandidate(
        from payload: [String: Any],
        payloadTurnId: String?,
        fallbackCallId: String? = nil
    ) -> CodexTranscriptUserInputCandidate? {
        let question = CodexTranscriptMonitorParser.userInputQuestionText(from: payload)
        let requestTurnId = CodexTranscriptMonitorParser.normalizedValue(request.turnId)
        let rawCallId = CodexTranscriptMonitorParser.firstString(in: payload, keys: ["call_id", "callId"]) ?? fallbackCallId
        let callId = CodexTranscriptMonitorParser.normalizedValue(rawCallId)
            ?? "\(payloadTurnId ?? requestTurnId ?? "session"):\(question ?? "request_user_input")"
        guard !publishedUserInputCallIds.contains(callId) else { return nil }
        return CodexTranscriptUserInputCandidate(callId: callId, question: question)
    }

    private func publishUserInput(_ userInput: CodexTranscriptUserInputCandidate) {
        publishedUserInputCallIds.insert(userInput.callId)
        let body = userInput.question ?? String(
            localized: "agent.codex.input.body.needsInput",
            defaultValue: "Codex is asking a question"
        )
        onEvent(.userInput(request: request, body: body))
    }

    private func publishFailure(_ failure: CodexTranscriptFailureCandidate) {
        onEvent(.failure(request: request, summary: CodexTranscriptMonitorParser.summarizeFailure(failure)))
    }

    private func findTranscriptPath() -> String? {
        CodexTranscriptPathResolver.findTranscriptPath(
            sessionId: request.sessionId,
            codexHome: request.codexHome
        )
    }

    private func resetTailState() {
        readOffset = 0
        pendingData.removeAll(keepingCapacity: false)
        discardingOversizedLine = false
    }
}
