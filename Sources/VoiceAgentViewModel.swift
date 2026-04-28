import Foundation

@MainActor
final class VoiceAgentViewModel: ObservableObject {
    @Published var state: VoiceConnectionState = .disconnected
    @Published var transcript: [VoiceTranscriptItem] = []
    @Published var promptText: String = ""
    @Published var isMuted: Bool = false
    @Published var currentActivity: String = ""
    @Published var microphoneLevel: Double = 0
    @Published var microphoneReady: Bool = false

    let bridge = VoiceRealtimeWebRTCBridge()

    private let clientSecretProvider = OpenAIRealtimeClientSecretProvider()
    private let toolExecutor = VoiceToolExecutor()
    private var handledCallIDs: Set<String> = []
    private var activeAssistantItemID: UUID?
    private var userTranscriptItemIDsByRealtimeItemID: [String: UUID] = [:]
    private var pendingUserTranscriptItemID: UUID?
    private var isResponseActive = false
    private var pendingResponseCreate = false
    private var inFlightFunctionCallCount = 0

    init() {
        bridge.delegate = self
    }

    func connect() {
        guard !state.isActive else { return }
        resetSessionState()
        state = .preparing
        append(.system, String(localized: "voice.log.preparing", defaultValue: "Preparing voice session."))

        Task {
            do {
                let configuration = OpenAIRealtimeSessionConfiguration(
                    instructions: Self.instructions,
                    tools: toolExecutor.toolDefinitions
                )
                let secret = try await clientSecretProvider.createClientSecret(configuration: configuration)
                state = .connecting
                bridge.connect(ephemeralKey: secret)
            } catch {
                state = .failed(error.localizedDescription)
                append(.error, error.localizedDescription)
            }
        }
    }

    func disconnect() {
        bridge.disconnect()
        state = .disconnected
        currentActivity = ""
        resetSessionState()
        microphoneLevel = 0
        microphoneReady = false
    }

    func toggleMute() {
        isMuted.toggle()
        bridge.setMuted(isMuted)
    }

    func sendPromptText() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        promptText = ""

        guard state.isConnected else {
            append(.error, String(localized: "voice.error.notConnected", defaultValue: "Voice is not connected."))
            return
        }

        append(.user, text)
        bridge.sendClientEvent([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": text
                    ]
                ]
            ]
        ])
        requestResponseCreate()
    }

    private func append(_ role: VoiceTranscriptRole, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transcript.append(VoiceTranscriptItem(role: role, text: trimmed))
    }

    private func appendAssistantDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        if let id = activeAssistantItemID,
           let index = transcript.firstIndex(where: { $0.id == id }) {
            transcript[index].text += delta
            return
        }

        let item = VoiceTranscriptItem(role: .assistant, text: delta)
        activeAssistantItemID = item.id
        transcript.append(item)
    }

    private func appendUserTranscriptionDelta(_ delta: VoiceRealtimeTextDelta) {
        if let id = transcriptIDForUserTranscription(itemID: delta.itemID),
           let index = transcript.firstIndex(where: { $0.id == id }) {
            if transcript[index].text == listeningPlaceholderText {
                transcript[index].text = delta.text
            } else {
                transcript[index].text += delta.text
            }
            return
        }

        let item = VoiceTranscriptItem(role: .user, text: delta.text)
        userTranscriptItemIDsByRealtimeItemID[delta.itemID] = item.id
        transcript.append(item)
    }

    private func completeUserTranscription(_ completed: VoiceRealtimeTextDelta) {
        if let id = transcriptIDForUserTranscription(itemID: completed.itemID),
           let index = transcript.firstIndex(where: { $0.id == id }) {
            transcript[index].text = completed.text
            clearPendingUserTranscriptIfNeeded(id: id)
            return
        }
        append(.user, completed.text)
    }

    private func beginUserSpeech(itemID: String?) {
        if let itemID,
           userTranscriptItemIDsByRealtimeItemID[itemID] != nil {
            return
        }

        if let pendingUserTranscriptItemID,
            transcript.contains(where: { $0.id == pendingUserTranscriptItemID }) {
            if let itemID {
                userTranscriptItemIDsByRealtimeItemID[itemID] = pendingUserTranscriptItemID
            }
            return
        }

        let item = VoiceTranscriptItem(role: .user, text: listeningPlaceholderText)
        pendingUserTranscriptItemID = item.id
        if let itemID {
            userTranscriptItemIDsByRealtimeItemID[itemID] = item.id
        }
        transcript.append(item)
    }

    private func transcriptIDForUserTranscription(itemID: String) -> UUID? {
        if let id = userTranscriptItemIDsByRealtimeItemID[itemID] {
            return id
        }

        if let pendingUserTranscriptItemID {
            userTranscriptItemIDsByRealtimeItemID[itemID] = pendingUserTranscriptItemID
            return pendingUserTranscriptItemID
        }

        return nil
    }

    private func clearPendingUserTranscriptIfNeeded(id: UUID) {
        guard pendingUserTranscriptItemID == id else { return }
        pendingUserTranscriptItemID = nil
    }

    private func finishAssistantMessage() {
        activeAssistantItemID = nil
    }

    private func handleServerEvent(_ event: [String: Any]) {
        if VoiceRealtimeEventParser.isActiveResponseError(in: event) {
            pendingResponseCreate = true
            currentActivity = String(localized: "voice.activity.thinking", defaultValue: "Thinking")
            return
        }

        if let error = VoiceRealtimeEventParser.errorMessage(in: event) {
            append(.error, error)
            currentActivity = ""
            return
        }

        let eventType = VoiceRealtimeEventParser.eventType(in: event)
        var shouldFlushPendingResponse = false

        switch eventType {
        case "input_audio_buffer.speech_started":
            currentActivity = String(localized: "voice.activity.listening", defaultValue: "Listening")
            beginUserSpeech(itemID: VoiceRealtimeEventParser.speechStartedItemID(in: event))
        case "input_audio_buffer.speech_stopped", "response.created":
            currentActivity = String(localized: "voice.activity.thinking", defaultValue: "Thinking")
            if eventType == "response.created" {
                isResponseActive = true
            }
        case "response.done":
            isResponseActive = false
            currentActivity = ""
            finishAssistantMessage()
            shouldFlushPendingResponse = true
        case "response.output_audio_transcript.done", "response.output_text.done":
            finishAssistantMessage()
        default:
            break
        }

        if let userText = VoiceRealtimeEventParser.completedUserText(in: event) {
            if let completed = VoiceRealtimeEventParser.completedUserTranscription(in: event) {
                completeUserTranscription(completed)
            } else {
                append(.user, userText)
            }
        }

        if let userDelta = VoiceRealtimeEventParser.userTranscriptionDelta(in: event) {
            appendUserTranscriptionDelta(userDelta)
        }

        if let delta = VoiceRealtimeEventParser.assistantDelta(in: event) {
            appendAssistantDelta(delta)
        }

        let functionCalls = VoiceRealtimeEventParser.functionCalls(in: event)
        for call in functionCalls {
            handleFunctionCall(call)
        }

        if shouldFlushPendingResponse && functionCalls.isEmpty {
            flushPendingResponseCreateIfNeeded()
        }
    }

    private func handleFunctionCall(_ call: VoiceRealtimeFunctionCall) {
        guard !handledCallIDs.contains(call.callID) else { return }
        handledCallIDs.insert(call.callID)
        inFlightFunctionCallCount += 1
        append(
            .tool,
            String(
                format: String(localized: "voice.tool.running", defaultValue: "Running %@"),
                call.name
            )
        )

        Task {
            let result = await toolExecutor.execute(name: call.name, argumentsJSON: call.arguments)
            append(
                .tool,
                String(
                    format: String(localized: "voice.tool.finished", defaultValue: "%@: %@"),
                    call.name,
                    result.displaySummary
                )
            )
            bridge.sendClientEvent([
                "type": "conversation.item.create",
                "item": [
                    "type": "function_call_output",
                    "call_id": call.callID,
                    "output": result.outputJSONString
                ]
            ])
            inFlightFunctionCallCount = max(0, inFlightFunctionCallCount - 1)
            if inFlightFunctionCallCount == 0 {
                requestResponseCreate()
            }
        }
    }

    private func requestResponseCreate() {
        guard state.isConnected else { return }
        if inFlightFunctionCallCount > 0 {
            pendingResponseCreate = true
            return
        }
        if isResponseActive {
            pendingResponseCreate = true
            return
        }
        pendingResponseCreate = false
        isResponseActive = true
        currentActivity = String(localized: "voice.activity.thinking", defaultValue: "Thinking")
        bridge.sendClientEvent(["type": "response.create"])
    }

    private func flushPendingResponseCreateIfNeeded() {
        guard pendingResponseCreate else { return }
        requestResponseCreate()
    }

    private func resetSessionState() {
        handledCallIDs.removeAll()
        activeAssistantItemID = nil
        userTranscriptItemIDsByRealtimeItemID.removeAll()
        pendingUserTranscriptItemID = nil
        isResponseActive = false
        pendingResponseCreate = false
        inFlightFunctionCallCount = 0
    }

    private var listeningPlaceholderText: String {
        String(localized: "voice.activity.listening", defaultValue: "Listening")
    }

    private static let instructions = """
    You are the cmux in-app voice agent. Keep spoken responses brief.

    You can inspect and control cmux through the provided tools. Use cmux_get_context before acting when the target workspace, terminal, pane, surface, or browser is ambiguous. Prefer the currently focused workspace and surface when the user's request clearly refers to "this", "here", or "current".

    For terminal commands:
    - Use cmux_run_command only when the user explicitly asks to run the exact command, or after they confirm.
    - Set confirmed to true only in those cases.
    - If a command is ambiguous, ask one short clarification.

    For browser actions:
    - Use cmux_open_browser or cmux_browser_navigate for navigation.
    - Use cmux_browser_snapshot before clicking or typing unless you already have a selector or element ref.

    Do not call destructive close, delete, sign-out, or destroy actions. If the user asks for destructive work, ask them to do it manually in cmux.
    """
}

extension VoiceAgentViewModel: VoiceRealtimeWebRTCBridgeDelegate {
    func voiceRealtimeBridge(_ bridge: VoiceRealtimeWebRTCBridge, didReceiveMessage message: [String: Any]) {
        let kind = message["kind"] as? String
        switch kind {
        case "bridge_ready":
            break
        case "state":
            handleBridgeState(message["state"] as? String)
        case "connection_state":
            break
        case "mute_state":
            if let muted = message["muted"] as? Bool {
                isMuted = muted
            }
        case "microphone_ready":
            microphoneReady = true
            append(.system, String(localized: "voice.log.microphoneReady", defaultValue: "Microphone ready."))
        case "audio_level":
            if let level = message["level"] as? Double {
                microphoneLevel = min(1, max(0, level))
            } else if let level = message["level"] as? NSNumber {
                microphoneLevel = min(1, max(0, level.doubleValue))
            }
        case "server_event":
            if let event = message["event"] as? [String: Any] {
                handleServerEvent(event)
            }
        case "error", "server_event_parse_error":
            let text = (message["message"] as? String) ?? String(localized: "voice.error.unknown", defaultValue: "Unknown voice error.")
            state = .failed(text)
            append(.error, text)
        case "log":
            if let text = message["message"] as? String {
                append(.system, text)
            }
        default:
            break
        }
    }

    private func handleBridgeState(_ rawState: String?) {
        switch rawState {
        case "connecting":
            state = .connecting
        case "connected":
            state = .connected
            currentActivity = ""
            append(.system, String(localized: "voice.log.connected", defaultValue: "Voice connected."))
        case "disconnected":
            state = .disconnected
            currentActivity = ""
            resetSessionState()
        case "failed":
            if !state.isActive {
                break
            }
            state = .failed(String(localized: "voice.error.connectionFailed", defaultValue: "Voice connection failed."))
            currentActivity = ""
            resetSessionState()
        default:
            break
        }
    }
}
