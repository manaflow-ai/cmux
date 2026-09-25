#if os(iOS)
import AVFAudio
import CmuxAgentChat
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation
import Observation
import OSLog

private let voiceSessionLog = Logger(subsystem: "dev.cmux.ios", category: "voice-session")

/// Drives one live voice conversation end to end: microphone capture, the
/// GPT-Live WebSocket, speech playback, transcripts, and the mode-specific
/// bridge to cmux.
///
/// Two modes share this one controller (shared-behavior rule: one action
/// path, multiple entrypoints):
/// - ``Mode/orchestrator``: GPT-Live fronts an OpenAI Responses backend that
///   holds our function tools; the app executes tool calls against the shell
///   store (list workspaces, read status, send prompts, interrupt).
/// - ``Mode/terminal(workspaceID:terminalID:)``: client delegation — the
///   coding agent in the terminal IS the backend. The user's delegated
///   utterances are sent to the agent session, and the agent's replies come
///   back through the chat event stream, reduced by ``SpeakableTextFilter``
///   before the voice speaks them.
@MainActor
@Observable
public final class VoiceSessionController {
    public enum Mode {
        case orchestrator
        case terminal(
            workspaceID: MobileWorkspacePreview.ID,
            terminalID: MobileTerminalPreview.ID?
        )
    }

    public enum FailureReason: Equatable, Sendable {
        case microphoneDenied
        case audioUnavailable
        /// No server grant and no user-provided key.
        case credentialMissing
        case connectionFailed
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case connecting
        case live
        case ended
        case failed(FailureReason)
    }

    public struct TranscriptLine: Identifiable, Equatable, Sendable {
        public enum Role: Sendable {
            case user
            case assistant
        }

        public let id: Int
        public let role: Role
        public var text: String
    }

    /// A destructive tool call held open until the user approves or denies
    /// it on screen (orchestrator mode, Bypass All Permissions off).
    public struct PendingToolApproval: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let callID: String
        public let toolName: String
        public let argumentsJSON: String
        /// Resolved human-readable target (e.g. the workspace name), when
        /// the arguments name one.
        public let target: String?
    }

    public private(set) var phase: Phase = .idle
    public private(set) var transcript: [TranscriptLine] = []
    /// Whether assistant speech is currently playing (drives the speaking
    /// indicator; GPT-Live is full duplex, so listening never stops).
    public private(set) var isAssistantSpeaking = false
    /// Terminal mode: no live agent session was found, so delegated speech is
    /// typed into the terminal instead of the agent chat.
    public private(set) var usesTerminalFallback = false
    /// Destructive tool calls awaiting the user's on-screen decision, FIFO.
    /// The sheet renders the first; tool calls are serial
    /// (`parallel_tool_calls: false`), so more than one pending entry only
    /// occurs across an approval the model talks through.
    public private(set) var pendingApprovals: [PendingToolApproval] = []

    public var microphoneMuted = false {
        didSet {
            guard microphoneMuted != oldValue else { return }
            audio.setMicrophoneMuted(microphoneMuted)
            let muted = microphoneMuted
            enqueueSend { client in
                try await client.send(muted ? .inputAudioMute : .inputAudioUnmute)
            }
        }
    }

    private let store: CMUXMobileShellStore
    private let settings: MobileVoiceSettings
    private let mode: Mode
    private let audio = VoiceChatAudioEngine()
    private var client: VoiceLiveSessionClient?
    private var eventTask: Task<Void, Never>?
    private var audioSendTask: Task<Void, Never>?
    private var chatRelayTask: Task<Void, Never>?
    private var sendQueueTask: Task<Void, Never>?
    private var sendQueue: AsyncStream<@Sendable (VoiceLiveSessionClient) async throws -> Void>.Continuation?
    private var transcriptIDCounter = 0
    /// Input transcript accumulated since the last client delegation, i.e.
    /// what the user has said that has not yet been forwarded to the agent.
    private var pendingUserUtterance = ""
    /// Terminal mode: the resolved agent chat session.
    private var chatSource: MobileChatEventSource?
    private var chatSessionID: String?

    public init(
        store: CMUXMobileShellStore,
        settings: MobileVoiceSettings,
        mode: Mode
    ) {
        self.store = store
        self.settings = settings
        self.mode = mode
    }

    // MARK: - Lifecycle

    public func start() {
        guard phase == .idle else { return }
        phase = .connecting
        Task { [weak self] in
            await self?.run()
        }
    }

    public func stop() {
        guard phase == .connecting || phase == .live else {
            teardown()
            return
        }
        phase = .ended
        let client = client
        Task {
            // Graceful close first so usage finalizes; the event loop drains
            // until `session.closed` or this deadline.
            await client?.requestClose()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await client?.shutdown()
        }
        teardown()
    }

    private func teardown() {
        audio.stop()
        eventTask?.cancel()
        audioSendTask?.cancel()
        chatRelayTask?.cancel()
        sendQueue?.finish()
        sendQueueTask?.cancel()
        eventTask = nil
        audioSendTask = nil
        chatRelayTask = nil
        sendQueueTask = nil
        sendQueue = nil
        isAssistantSpeaking = false
    }

    private func run() async {
        guard await Self.ensureMicrophonePermission() else {
            phase = .failed(.microphoneDenied)
            return
        }
        // Bring-your-own-key only: the credential is the user's OpenAI key
        // from the device keychain. Nothing cmux-operated ever holds or
        // distributes a voice credential.
        let apiKey = settings.userOpenAIAPIKey
        guard !apiKey.isEmpty else {
            voiceSessionLog.error("voice session start without a configured OpenAI key")
            phase = .failed(.credentialMissing)
            return
        }
        guard phase == .connecting else { return }

        let client = VoiceLiveSessionClient(endpoint: Self.liveEndpoint, bearerToken: apiKey)
        self.client = client
        startSendQueue(client: client)

        // Audio first: hearing "Connecting…" flip to live with a dead mic is
        // the failure mode we must not ship.
        let audioReady = await withCheckedContinuation { continuation in
            startAudio(client: client) { ready in
                continuation.resume(returning: ready)
            }
        }
        guard audioReady else {
            phase = .failed(.audioUnavailable)
            await client.shutdown()
            return
        }

        let events = await client.events()
        let config = await makeSessionConfig(model: Self.liveModel)
        enqueueSend { client in
            try await client.send(.sessionStart(config))
        }

        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
            await self?.handleStreamFinished()
        }
    }

    private static func ensureMicrophonePermission() async -> Bool {
        // Read synchronously first: the async request path has a documented
        // main-actor re-entry hazard when TCC answers from cache (see
        // ComposerDictationController.resolvedAuthorization).
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            fallthrough
        @unknown default:
            return await AVAudioApplication.requestRecordPermission()
        }
    }

    /// The GPT-Live WebSocket endpoint and model. Fixed constants: GPT-Live
    /// has no ephemeral client-secret mint yet, so there is deliberately no
    /// server-delivered credential or configuration path.
    private static let liveEndpoint = URL(string: "wss://api.openai.com/v1/live/sessions")!
    private static let liveModel = "gpt-live-1"

    private func startAudio(
        client: VoiceLiveSessionClient,
        onReady: @escaping @Sendable (Bool) -> Void
    ) {
        audio.start(
            onCapturedAudio: { [weak self] chunk in
                // Realtime-adjacent callback: enqueue without touching state.
                Task { [weak self] in
                    await self?.forwardCapturedAudio(chunk)
                }
            },
            onPlaybackActivity: { [weak self] active in
                Task { @MainActor [weak self] in
                    self?.isAssistantSpeaking = active
                }
            },
            onReady: onReady
        )
    }

    private func forwardCapturedAudio(_ chunk: Data) {
        enqueueSend { client in
            try await client.send(.inputAudioAppend(chunk))
        }
    }

    /// All client sends are serialized through one queue so audio chunks stay
    /// ordered and control events interleave cleanly with them.
    private func startSendQueue(client: VoiceLiveSessionClient) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: (@Sendable (VoiceLiveSessionClient) async throws -> Void).self
        )
        sendQueue = continuation
        sendQueueTask = Task {
            for await operation in stream {
                do {
                    try await operation(client)
                } catch {
                    // A dead socket surfaces through the event stream as
                    // `closed`; dropping the send here is correct.
                }
            }
        }
    }

    private func enqueueSend(
        _ operation: @escaping @Sendable (VoiceLiveSessionClient) async throws -> Void
    ) {
        sendQueue?.yield(operation)
    }

    // MARK: - Session config

    private func makeSessionConfig(model: String) async -> VoiceLiveSessionConfig {
        switch mode {
        case .orchestrator:
            let bypass = settings.orchestratorBypassPermissions
            return VoiceLiveSessionConfig(
                model: model,
                voice: settings.voiceName,
                instructions: Self.orchestratorVoiceInstructions(bypassPermissions: bypass),
                delegation: .responses(
                    model: Self.orchestratorBackendModel,
                    instructions: Self.orchestratorBackendInstructions(bypassPermissions: bypass),
                    tools: VoiceOrchestratorToolExecutor.tools
                )
            )
        case .terminal(let workspaceID, _):
            let workspaceName = store.workspaces
                .first(where: { $0.id == workspaceID })?.name ?? "this workspace"
            return VoiceLiveSessionConfig(
                model: model,
                voice: settings.voiceName,
                instructions: Self.terminalVoiceInstructions(workspaceName: workspaceName),
                delegation: .client
            )
        }
    }

    /// The Responses model behind the orchestrator voice. Fixed for now;
    /// becomes a setting if model choice ever matters to users.
    private static let orchestratorBackendModel = "gpt-5.6-terra"

    private static func orchestratorVoiceInstructions(bypassPermissions: Bool) -> String {
        let confirmation = bypassPermissions
            ? "The user has enabled Bypass All Permissions: act on requests immediately without asking for confirmation first."
            : "Confirm with the user before acting on a workspace (sending prompts, answering for the agent, interrupting, renaming, closing)."
        return """
        You are the voice assistant for cmux, an app for running AI coding \
        agents in terminal workspaces on the user's computers. Be brief and \
        conversational. Delegate any request about the user's workspaces, \
        agents, or notifications to the backend; it can read everything and \
        act on the app like an on-device user. \(confirmation)
        """
    }

    private static func orchestratorBackendInstructions(bypassPermissions: Bool) -> String {
        let approval = bypassPermissions
            ? "The user has enabled Bypass All Permissions: execute tools immediately, destructive ones included, without waiting for approval."
            : """
            Acting tools need the user's spoken confirmation first. \
            Destructive tools (close_workspace) additionally show the user an \
            on-screen approval card: after calling one, tell the user to \
            approve or deny on screen and wait for the tool result.
            """
        return """
        You act on the user's cmux app through the provided tools: read \
        workspaces, agent conversations, and notifications; send prompts and \
        answers to agents; open, create, rename, pin, and close workspaces; \
        manage read state. Ground every answer in a read tool first; never \
        invent workspace names or states. \(approval) Keep results short and \
        speakable: no code, no markdown, no long paths.
        """
    }

    private static func terminalVoiceInstructions(workspaceName: String) -> String {
        """
        You are the voice link between the user and the AI coding agent \
        working in the cmux workspace "\(workspaceName)". Delegate every \
        instruction, question, or reply that is meant for the coding agent. \
        Notes about the agent's progress and its replies are appended to \
        your context; relay them briefly and naturally, skipping code and \
        technical noise. If the user is only talking to you, answer directly \
        without delegating. Keep everything short.
        """
    }

    // MARK: - Server events

    private func handle(_ event: VoiceLiveServerEvent) async {
        switch event {
        case .started:
            phase = .live
            if case .terminal = mode {
                await attachToAgentSession()
            }
        case .outputAudioDelta(let data):
            audio.enqueuePlayback(data)
        case .inputTranscriptDelta(let delta):
            pendingUserUtterance += delta
            appendTranscript(role: .user, delta: delta)
        case .outputTranscriptDelta(let delta):
            appendTranscript(role: .assistant, delta: delta)
        case .delegationCreated(let id, let target):
            if target == "client" {
                await forwardUtteranceToAgent(delegationID: id)
            }
        case .functionCall(let callID, let name, let argumentsJSON, _):
            await handleFunctionCall(callID: callID, name: name, argumentsJSON: argumentsJSON)
        case .errorEvent(let code, let message):
            voiceSessionLog.error(
                "live session error code=\(code ?? "?", privacy: .public) message=\(message ?? "", privacy: .public)"
            )
        case .closed:
            if phase == .live || phase == .connecting {
                phase = phase == .connecting ? .failed(.connectionFailed) : .ended
            }
            teardown()
        case .usageUpdated, .other:
            break
        }
    }

    /// Execute a backend tool call, or hold a destructive one open on the
    /// on-screen approval card. The held call's output is only sent after
    /// ``resolvePendingApproval(_:approved:)``, so the app (not the model)
    /// enforces the confirmation.
    private func handleFunctionCall(
        callID: String, name: String, argumentsJSON: String
    ) async {
        let permission = VoiceToolCatalog.permission(forTool: name)
        if permission == .destructive, !settings.orchestratorBypassPermissions {
            let executor = VoiceOrchestratorToolExecutor(store: store)
            let approval = PendingToolApproval(
                id: UUID(),
                callID: callID,
                toolName: name,
                argumentsJSON: argumentsJSON,
                target: executor.approvalTarget(forTool: name, argumentsJSON: argumentsJSON)
            )
            pendingApprovals.append(approval)
            enqueueThinking(
                """
                cmux is showing the user an on-screen approval card for the \
                destructive action "\(name)"\(approval.target.map { " on \($0)" } ?? ""). \
                Tell the user to approve or deny it on screen, and do not \
                assume the outcome; the tool result will arrive after they \
                decide.
                """
            )
            return
        }
        await executeFunctionCall(callID: callID, name: name, argumentsJSON: argumentsJSON)
    }

    private func executeFunctionCall(
        callID: String, name: String, argumentsJSON: String
    ) async {
        let executor = VoiceOrchestratorToolExecutor(store: store)
        let output = await executor.execute(name: name, argumentsJSON: argumentsJSON)
        enqueueSend { client in
            try await client.send(.functionCallOutput(callID: callID, output: output))
            try await client.send(.responseCreate)
        }
    }

    /// The user decided the approval card. Approved calls execute now; denied
    /// ones return a denial as the tool output so the conversation moves on.
    public func resolvePendingApproval(_ id: UUID, approved: Bool) {
        guard let index = pendingApprovals.firstIndex(where: { $0.id == id }) else { return }
        let approval = pendingApprovals.remove(at: index)
        Task { [weak self] in
            guard let self else { return }
            if approved {
                await self.executeFunctionCall(
                    callID: approval.callID,
                    name: approval.toolName,
                    argumentsJSON: approval.argumentsJSON
                )
            } else {
                self.enqueueSend { client in
                    try await client.send(.functionCallOutput(
                        callID: approval.callID,
                        output: "The user denied this action on the approval card. Do not retry it unless asked."
                    ))
                    try await client.send(.responseCreate)
                }
            }
        }
    }

    private func handleStreamFinished() {
        if phase == .connecting {
            phase = .failed(.connectionFailed)
        } else if phase == .live {
            phase = .ended
        }
        teardown()
    }

    private func appendTranscript(role: TranscriptLine.Role, delta: String) {
        guard !delta.isEmpty else { return }
        if let last = transcript.indices.last, transcript[last].role == role {
            transcript[last].text += delta
        } else {
            transcriptIDCounter += 1
            transcript.append(TranscriptLine(id: transcriptIDCounter, role: role, text: delta))
        }
    }

    // MARK: - Terminal mode: agent bridge

    /// Resolve the workspace's agent chat session and start relaying its
    /// events into the voice conversation.
    private func attachToAgentSession() async {
        guard case .terminal(let workspaceID, let terminalID) = mode,
              let workspace = store.workspaces.first(where: { $0.id == workspaceID })
        else { return }
        guard let source = store.makeChatEventSource(),
              let sessions = try? await source.sessions(
                workspaceID: workspace.rpcWorkspaceID.rawValue
              )
        else {
            usesTerminalFallback = true
            return
        }
        let preferred = terminalID.flatMap { terminal in
            sessions.first { $0.terminalID == terminal.rawValue && $0.state != .ended }
        }
        guard let session = preferred ?? ChatSessionDescriptor.openable(sessions).first,
              session.state != .ended
        else {
            usesTerminalFallback = true
            return
        }
        chatSource = source
        chatSessionID = session.id
        usesTerminalFallback = false
        chatRelayTask = Task { [weak self] in
            let events = await source.events(sessionID: session.id)
            for await event in events {
                guard let self else { return }
                await self.relayAgentEvent(event)
            }
        }
    }

    private func relayAgentEvent(_ event: ChatSessionEvent) async {
        switch event {
        case .appended(let messages), .updated(let messages):
            // `.updated` rewrites existing rows (e.g. a tool run finishing);
            // only speak from `.appended` to avoid repeating a reply.
            if case .updated = event { return }
            for message in messages where message.role == .agent {
                speakAgentMessage(message)
            }
        case .stateChanged(let state):
            relayAgentState(state)
        case .streamingProse, .descriptorChanged, .terminalBlocks,
             .reset, .sessionRemoved, .unknown:
            break
        }
    }

    private func speakAgentMessage(_ message: ChatMessage) {
        guard settings.speakAgentReplies else { return }
        switch message.kind {
        case .prose(let prose):
            let speakable = SpeakableTextFilter.speakableText(
                from: prose.text,
                options: settings.speakableTextOptions
            )
            guard !speakable.isEmpty else { return }
            enqueueCommentary("The coding agent replied: \(speakable)")
        case .question(let question):
            var prompt = SpeakableTextFilter.speakableText(
                from: question.prompt,
                options: settings.speakableTextOptions
            )
            if !question.options.isEmpty {
                let labels = question.options.map(\.label).joined(separator: ", ")
                prompt += " The options are: \(labels)."
            }
            enqueueCommentary("The coding agent is asking: \(prompt)")
        case .toolUse(let tool):
            guard settings.speakToolActivity else { return }
            enqueueThinking("The agent ran a tool: \(tool.summary).")
        case .fileEdit, .terminal, .thought, .permissionRequest,
             .status, .attachment, .unsupported:
            break
        }
    }

    private func relayAgentState(_ state: ChatAgentState) {
        switch state {
        case .working:
            enqueueThinking("The coding agent has started working.")
        case .idle:
            enqueueThinking("The coding agent is idle and ready for input.")
        case .needsInput:
            guard settings.speakAgentReplies else { return }
            enqueueCommentary("The coding agent is waiting for the user's input.")
        case .ended:
            enqueueCommentary("The coding agent session has ended.")
        }
    }

    /// Client delegation fired: everything the user has said since the last
    /// forward is the task text. Deliver it to the agent session (or type it
    /// into the terminal when no session exists) and tell the voice model
    /// what happened.
    private func forwardUtteranceToAgent(delegationID: String) async {
        guard case .terminal(let workspaceID, let terminalID) = mode else { return }
        let utterance = pendingUserUtterance.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingUserUtterance = ""
        guard !utterance.isEmpty else { return }

        var delivered = false
        if let chatSource, let chatSessionID {
            delivered = (try? await chatSource.send(
                text: utterance,
                attachments: [],
                sessionID: chatSessionID
            )) != nil
        }
        if !delivered {
            let workspace = store.workspaces.first(where: { $0.id == workspaceID })
            let fallbackTerminal = terminalID
                ?? workspace?.terminals.first(where: \.isReady)?.id
                ?? workspace?.terminals.first?.id
            if let fallbackTerminal {
                delivered = await store.sendTerminalPaste(
                    utterance,
                    workspaceID: workspaceID,
                    terminalID: fallbackTerminal
                )
                usesTerminalFallback = delivered
            }
        }
        let note = delivered
            ? "Delivered to the coding agent: \"\(utterance)\". Its reply will be appended here when it arrives; work may take a while."
            : "Could not deliver the message to the coding agent — the workspace has no reachable session or terminal. Tell the user."
        enqueueSend { client in
            try await client.send(.thinkingAppend(text: note, delegationID: delegationID))
        }
    }

    // MARK: - Context appends

    /// Commentary appends are capped at 500 tokens upstream; chunk on
    /// sentence boundaries well below that so nothing is rejected.
    private static let appendChunkLimit = 1_200

    private func enqueueCommentary(_ text: String) {
        for chunk in Self.chunked(text, limit: Self.appendChunkLimit) {
            enqueueSend { client in
                try await client.send(.commentaryAppend(text: chunk, delegationID: nil))
            }
        }
    }

    private func enqueueThinking(_ text: String) {
        for chunk in Self.chunked(text, limit: Self.appendChunkLimit) {
            enqueueSend { client in
                try await client.send(.thinkingAppend(text: chunk, delegationID: nil))
            }
        }
    }

    static func chunked(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var chunks: [String] = []
        var remainder = Substring(text)
        while remainder.count > limit {
            let window = remainder.prefix(limit)
            let cut = window.lastIndex(where: { ".!?\n".contains($0) })
                ?? window.lastIndex(of: " ")
                ?? window.endIndex
            let end = cut == window.endIndex ? window.endIndex : window.index(after: cut)
            chunks.append(String(remainder[..<end]))
            remainder = remainder[end...]
        }
        if !remainder.isEmpty {
            chunks.append(String(remainder))
        }
        return chunks
    }
}
#endif
