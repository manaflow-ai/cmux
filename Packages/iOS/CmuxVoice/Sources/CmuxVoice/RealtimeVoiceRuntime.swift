#if os(iOS)
public import Observation

/// Constructs a one-shot Realtime session for a terminal tool executor.
public typealias RealtimeVoiceSessionBuilder = @Sendable (
    any RealtimeVoiceToolExecuting
) -> RealtimeVoiceSession

/// Main-actor Voice Mode coordinator injected from the iOS composition root.
@MainActor
@Observable
public final class RealtimeVoiceRuntime {
    /// Current renderable lifecycle state.
    public private(set) var state: RealtimeVoiceRuntimeState = .idle
    /// Finalized conversation turns, capped to bound observation and memory work.
    public private(set) var transcripts: [RealtimeVoiceTranscriptEntry] = []
    /// Incremental user transcript for the active turn.
    public private(set) var partialUserTranscript = ""
    /// Incremental assistant transcript for the active response.
    public private(set) var partialAssistantTranscript = ""
    /// Most recent classified failure.
    public private(set) var failure: RealtimeVoiceSessionFailure?

    private let makeSession: RealtimeVoiceSessionBuilder
    private var session: RealtimeVoiceSession?
    private var eventTask: Task<Void, Never>?
    private var stateBeforeToolActivity: RealtimeVoiceRuntimeState = .listening

    /// Creates the runtime with a composition-root session builder.
    /// - Parameter makeSession: Builds fresh service instances for each listening session.
    public init(makeSession: @escaping RealtimeVoiceSessionBuilder) {
        self.makeSession = makeSession
    }

    /// Start a fresh conversational session.
    /// - Parameter toolExecutor: Live cross-Mac terminal inventory and delivery adapter.
    public func start(toolExecutor: any RealtimeVoiceToolExecuting) async {
        guard state == .idle || state == .failed else { return }
        eventTask?.cancel()
        transcripts.removeAll(keepingCapacity: true)
        partialUserTranscript = ""
        partialAssistantTranscript = ""
        failure = nil
        state = .connecting

        let session = makeSession(toolExecutor)
        self.session = session
        eventTask = Task { @MainActor [weak self] in
            for await event in session.events {
                guard !Task.isCancelled else { return }
                self?.handle(event)
            }
        }
        await session.start()
    }

    /// Stop the current session and release microphone and playback ownership.
    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        let activeSession = session
        session = nil
        await activeSession?.stop()
        partialUserTranscript = ""
        partialAssistantTranscript = ""
        if state != .failed {
            state = .idle
        }
    }

    private func handle(_ event: RealtimeVoiceSessionEvent) {
        switch event {
        case .connected:
            state = .listening
        case .userTranscriptDelta(let delta):
            partialUserTranscript += delta
        case .userTranscriptCompleted(let transcript):
            partialUserTranscript = ""
            appendTranscript(role: .user, text: transcript)
        case .assistantTranscriptDelta(let delta):
            partialAssistantTranscript += delta
        case .assistantTranscriptCompleted(let transcript):
            partialAssistantTranscript = ""
            appendTranscript(role: .assistant, text: transcript)
        case .assistantSpeechStarted:
            state = .speaking
        case .assistantSpeechEnded:
            state = .listening
        case .toolActivity(let active):
            if active {
                stateBeforeToolActivity = state == .working ? .listening : state
                state = .working
            } else if state == .working {
                state = stateBeforeToolActivity == .speaking ? .speaking : .listening
            }
        case .failed(let failure):
            self.failure = failure
            state = .failed
        case .disconnected:
            if state != .failed {
                state = .idle
            }
        }
    }

    private func appendTranscript(
        role: RealtimeVoiceTranscriptRole,
        text: String
    ) {
        transcripts.append(RealtimeVoiceTranscriptEntry(role: role, text: text))
        if transcripts.count > 50 {
            transcripts.removeFirst(transcripts.count - 50)
        }
    }
}
#endif
