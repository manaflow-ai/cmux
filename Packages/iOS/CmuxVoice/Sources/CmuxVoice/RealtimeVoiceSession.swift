#if os(iOS)
public import Foundation

/// Owns one low-latency GPT Realtime speech-to-speech conversation.
public actor RealtimeVoiceSession {
    /// Observable lifecycle, transcript, speech, and failure events.
    public nonisolated let events: AsyncStream<RealtimeVoiceSessionEvent>

    private let eventContinuation: AsyncStream<RealtimeVoiceSessionEvent>.Continuation
    private let clientSecretProvider: any RealtimeVoiceClientSecretProviding
    private let toolExecutor: any RealtimeVoiceToolExecuting
    private let audioIO: any RealtimeVoiceAudioIO
    private let urlSession: URLSession
    private let decoder = RealtimeVoiceServerEventDecoder()

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var audioSendTask: Task<Void, Never>?
    private var started = false
    private var terminated = false
    private var announcedConnected = false
    private var assistantSpeaking = false
    private var latestInputItemID: String?
    private var inputTranscripts: [String: String] = [:]
    private var unavailableTranscriptInputItemIDs: Set<String> = []
    private var inputItemIDByResponseID: [String: String] = [:]
    private var pendingTranscriptCallsByInputItemID:
        [String: [RealtimeVoiceFunctionCall]] = [:]
    private var executedCallIDs: Set<String> = []
    private var deliveredInputItemIDs: Set<String> = []

    /// Creates a one-shot Realtime session from injected services.
    /// - Parameters:
    ///   - clientSecretProvider: Authenticated cmux credential broker.
    ///   - toolExecutor: App-owned cross-Mac terminal actions.
    ///   - audioIO: Full-duplex 24 kHz PCM audio service.
    ///   - urlSession: WebSocket transport session.
    public init(
        clientSecretProvider: any RealtimeVoiceClientSecretProviding,
        toolExecutor: any RealtimeVoiceToolExecuting,
        audioIO: any RealtimeVoiceAudioIO,
        urlSession: URLSession = .shared
    ) {
        let pair = AsyncStream.makeStream(
            of: RealtimeVoiceSessionEvent.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        self.events = pair.stream
        self.eventContinuation = pair.continuation
        self.clientSecretProvider = clientSecretProvider
        self.toolExecutor = toolExecutor
        self.audioIO = audioIO
        self.urlSession = urlSession
    }

    /// Start credential acquisition, WebSocket transport, and full-duplex audio.
    public func start() async {
        guard !started, !terminated else { return }
        started = true
        do {
            let secret = try await clientSecretProvider.fetchClientSecret()
            guard let url = Self.realtimeURL(model: secret.model) else {
                await terminate(failure: .serviceUnavailable)
                return
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("Bearer \(secret.value)", forHTTPHeaderField: "Authorization")
            let socket = urlSession.webSocketTask(with: request)
            socket.maximumMessageSize = 2 * 1_024 * 1_024
            webSocketTask = socket
            socket.resume()

            let microphoneChunks: AsyncStream<Data>
            do {
                microphoneChunks = try await audioIO.start()
            } catch {
                await terminate(failure: .audioUnavailable)
                return
            }
            receiveTask = Task { [weak self, weak socket] in
                guard let self, let socket else { return }
                await self.receiveLoop(socket: socket)
            }
            audioSendTask = Task { [weak self, weak socket] in
                guard let self, let socket else { return }
                await self.sendAudioLoop(microphoneChunks, socket: socket)
            }
        } catch let error as RealtimeVoiceClientSecretError {
            await terminate(failure: Self.sessionFailure(for: error))
        } catch {
            await terminate(failure: .serviceUnavailable)
        }
    }

    /// Stop the one-shot session and release its microphone and playback route.
    public func stop() async {
        await terminate(failure: nil)
    }

    private func receiveLoop(socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled, !terminated {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .data(let bytes):
                    data = bytes
                case .string(let text):
                    guard let bytes = text.data(using: .utf8) else { continue }
                    data = bytes
                @unknown default:
                    continue
                }
                guard let event = decoder.decode(data) else { continue }
                try await handle(event, socket: socket)
            }
        } catch {
            if !Task.isCancelled, !terminated {
                await terminate(failure: .connectionLost)
            }
        }
    }

    private func sendAudioLoop(
        _ microphoneChunks: AsyncStream<Data>,
        socket: URLSessionWebSocketTask
    ) async {
        do {
            for await chunk in microphoneChunks {
                guard !Task.isCancelled, !terminated else { return }
                try await sendEvent(
                    [
                        "type": "input_audio_buffer.append",
                        "audio": chunk.base64EncodedString(),
                    ],
                    socket: socket
                )
            }
        } catch {
            if !Task.isCancelled, !terminated {
                await terminate(failure: .connectionLost)
            }
        }
    }

    private func handle(
        _ event: RealtimeVoiceServerEvent,
        socket: URLSessionWebSocketTask
    ) async throws {
        switch event {
        case .sessionReady:
            if !announcedConnected {
                announcedConnected = true
                eventContinuation.yield(.connected)
            }
        case .inputCommitted(let itemID):
            latestInputItemID = itemID
        case .inputTranscriptDelta(let itemID, let delta):
            latestInputItemID = itemID
            eventContinuation.yield(.userTranscriptDelta(delta))
        case .inputTranscriptCompleted(let itemID, let transcript):
            latestInputItemID = itemID
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                inputTranscripts[itemID] = trimmed
                eventContinuation.yield(.userTranscriptCompleted(trimmed))
            } else {
                unavailableTranscriptInputItemIDs.insert(itemID)
            }
            if let pending = pendingTranscriptCallsByInputItemID.removeValue(
                forKey: itemID
            ) {
                try await executeFunctionCalls(
                    pending,
                    inputItemID: itemID,
                    socket: socket
                )
            }
        case .inputTranscriptFailed(let itemID):
            unavailableTranscriptInputItemIDs.insert(itemID)
            if let pending = pendingTranscriptCallsByInputItemID.removeValue(
                forKey: itemID
            ) {
                try await executeFunctionCalls(
                    pending,
                    inputItemID: itemID,
                    socket: socket
                )
            }
        case .outputAudioDelta(let itemID, let data):
            if !assistantSpeaking {
                assistantSpeaking = true
                eventContinuation.yield(.assistantSpeechStarted)
            }
            await audioIO.enqueuePlayback(data, itemID: itemID)
        case .outputAudioDone:
            if assistantSpeaking {
                assistantSpeaking = false
                eventContinuation.yield(.assistantSpeechEnded)
            }
        case .outputTranscriptDelta(let delta):
            eventContinuation.yield(.assistantTranscriptDelta(delta))
        case .outputTranscriptCompleted(let transcript):
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                eventContinuation.yield(.assistantTranscriptCompleted(trimmed))
            }
        case .speechStarted:
            if let progress = await audioIO.interruptPlayback() {
                try await sendEvent(
                    [
                        "type": "conversation.item.truncate",
                        "item_id": progress.itemID,
                        "content_index": 0,
                        "audio_end_ms": progress.audioEndMilliseconds,
                    ],
                    socket: socket
                )
            }
            if assistantSpeaking {
                assistantSpeaking = false
                eventContinuation.yield(.assistantSpeechEnded)
            }
        case .responseCreated(let responseID):
            if let latestInputItemID {
                inputItemIDByResponseID[responseID] = latestInputItemID
            }
        case .responseDone(let responseID, let calls):
            let inputItemID = responseID.flatMap {
                inputItemIDByResponseID.removeValue(forKey: $0)
            }
            if !calls.isEmpty {
                try await executeFunctionCalls(
                    calls,
                    inputItemID: inputItemID,
                    socket: socket
                )
            }
        case .serviceError:
            await terminate(failure: .serviceUnavailable)
        case .ignored:
            break
        }
    }

    private func executeFunctionCalls(
        _ calls: [RealtimeVoiceFunctionCall],
        inputItemID: String?,
        socket: URLSessionWebSocketTask
    ) async throws {
        var deferred = [RealtimeVoiceFunctionCall]()
        var emittedOutput = false
        eventContinuation.yield(.toolActivity(true))
        defer { eventContinuation.yield(.toolActivity(false)) }

        for call in calls where !executedCallIDs.contains(call.callID) {
            guard let toolCall = call.decodedToolCall() else {
                try await sendToolOutput(
                    callID: call.callID,
                    output: #"{"ok":false,"error":"invalid_tool_call"}"#,
                    socket: socket
                )
                executedCallIDs.insert(call.callID)
                emittedOutput = true
                continue
            }
            let transcript = inputItemID.flatMap { inputTranscripts[$0] }
            if case .sendLatestUtterance = toolCall, inputItemID == nil {
                try await sendToolOutput(
                    callID: call.callID,
                    output: #"{"ok":false,"error":"utterance_unbound"}"#,
                    socket: socket
                )
                executedCallIDs.insert(call.callID)
                emittedOutput = true
                continue
            }
            if case .sendLatestUtterance = toolCall,
               let inputItemID,
               unavailableTranscriptInputItemIDs.contains(inputItemID) {
                try await sendToolOutput(
                    callID: call.callID,
                    output: #"{"ok":false,"error":"transcript_unavailable"}"#,
                    socket: socket
                )
                executedCallIDs.insert(call.callID)
                emittedOutput = true
                continue
            }
            if case .sendLatestUtterance = toolCall, transcript == nil {
                deferred.append(call)
                continue
            }
            if case .sendLatestUtterance = toolCall,
               let inputItemID,
               deliveredInputItemIDs.contains(inputItemID) {
                try await sendToolOutput(
                    callID: call.callID,
                    output: #"{"ok":false,"error":"utterance_already_sent"}"#,
                    socket: socket
                )
                executedCallIDs.insert(call.callID)
                emittedOutput = true
                continue
            }

            let result = await toolExecutor.execute(
                toolCall,
                latestUserTranscript: transcript
            )
            try await sendToolOutput(
                callID: call.callID,
                output: result.output,
                socket: socket
            )
            executedCallIDs.insert(call.callID)
            if result.deliveredLatestUtterance, let inputItemID {
                deliveredInputItemIDs.insert(inputItemID)
            }
            emittedOutput = true
        }
        if let inputItemID, !deferred.isEmpty {
            pendingTranscriptCallsByInputItemID[inputItemID, default: []]
                .append(contentsOf: deferred)
        }
        if emittedOutput, deferred.isEmpty {
            try await sendEvent(["type": "response.create"], socket: socket)
        }
    }

    private func sendToolOutput(
        callID: String,
        output: String,
        socket: URLSessionWebSocketTask
    ) async throws {
        try await sendEvent(
            [
                "type": "conversation.item.create",
                "item": [
                    "type": "function_call_output",
                    "call_id": callID,
                    "output": output,
                ],
            ],
            socket: socket
        )
    }

    private func sendEvent(
        _ event: [String: Any],
        socket: URLSessionWebSocketTask
    ) async throws {
        guard JSONSerialization.isValidJSONObject(event) else {
            throw RealtimeVoiceSessionFailure.serviceUnavailable
        }
        let data = try JSONSerialization.data(withJSONObject: event)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeVoiceSessionFailure.serviceUnavailable
        }
        try await socket.send(.string(text))
    }

    private func terminate(failure: RealtimeVoiceSessionFailure?) async {
        guard !terminated else { return }
        terminated = true
        receiveTask?.cancel()
        audioSendTask?.cancel()
        receiveTask = nil
        audioSendTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        await audioIO.stop()
        if let failure {
            eventContinuation.yield(.failed(failure))
        }
        eventContinuation.yield(.disconnected)
        eventContinuation.finish()
    }

    private static func realtimeURL(model: String) -> URL? {
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")
        components?.queryItems = [URLQueryItem(name: "model", value: model)]
        return components?.url
    }

    private static func sessionFailure(
        for error: RealtimeVoiceClientSecretError
    ) -> RealtimeVoiceSessionFailure {
        switch error {
        case .notAuthenticated:
            return .notAuthenticated
        case .rateLimited:
            return .rateLimited
        case .invalidConfiguration, .serviceUnavailable, .invalidResponse:
            return .serviceUnavailable
        }
    }
}
#endif
