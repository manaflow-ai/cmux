import Foundation
import Observation

/// The Realtime session voice mode opens: a relay voice, not an assistant.
/// The model never answers on its own (`create_response: false`): it only
/// speaks the agent's words it is handed, and the user's speech is
/// transcribed and goes to the agent as a prompt.
public struct AgentVoiceSessionConfig: Sendable, Equatable {
    public var model: String
    public var voice: String
    public var agentName: String
    public var transcriptionModel: String

    public init(model: String, voice: String, agentName: String,
                transcriptionModel: String = VoiceCallSessionConfig.preferredTranscriptionModel) {
        self.model = model
        self.voice = voice
        self.agentName = agentName
        self.transcriptionModel = transcriptionModel
    }

    /// How every spoken response is told to read: verbatim, nothing added.
    public var readInstructions: String {
        """
        You are the voice of \(agentName), a coding agent, in a voice-only relay. Read the user message \
        aloud exactly as written, word for word, in a calm natural voice. Do not answer it, summarize it, \
        add to it, greet, or comment. Say file names and numbers naturally.
        """
    }

    public var json: Data {
        let session: [String: Any] = [
            "type": "realtime",
            "model": model,
            "instructions": readInstructions,
            "output_modalities": ["audio"],
            "audio": [
                "input": [
                    "transcription": ["model": transcriptionModel],
                    // The model never replies to speech: what the user says is a prompt for the
                    // agent. Speaking still stops the voice (barge-in).
                    "turn_detection": ["type": "semantic_vad", "create_response": false, "interrupt_response": true],
                    "noise_reduction": ["type": "near_field"],
                ] as [String: Any],
                "output": ["voice": voice],
            ],
            "tools": [] as [Any],
            "tool_choice": "none",
        ]
        return (try? JSONSerialization.data(withJSONObject: session, options: [.sortedKeys])) ?? Data()
    }

    /// An out-of-band response that reads `text` aloud and leaves the
    /// conversation empty, so earlier readings never colour the next.
    func readEvent(_ text: String) -> Data {
        let object: [String: Any] = [
            "type": "response.create",
            "response": [
                "conversation": "none",
                "output_modalities": ["audio"],
                "instructions": readInstructions,
                "input": [["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]],
            ] as [String: Any],
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

/// One caption in voice mode.
public struct AgentVoiceLine: Identifiable, Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        /// What the user said: sent to the agent.
        case you
        /// The agent's words, as read aloud.
        case agent
    }

    public let id: String
    public var role: Role
    public var text: String
    public var isFinal: Bool
}

/// Voice mode on one agent session: a direct line. New agent output is read
/// aloud (``relay(_:)``, already filtered by ``AgentVoiceSpeech``), one
/// reading at a time, in order; each finished user utterance goes to
/// ``onUserSaid`` and from there into the session. Event driven, no timers.
@MainActor
@Observable
public final class AgentVoiceSession: Identifiable {
    public enum Phase: Sendable, Equatable {
        case connecting
        case live
        case ended(VoiceCallFailure?)
    }

    public nonisolated let id = UUID()
    public private(set) var phase: Phase = .connecting
    public private(set) var lines: [AgentVoiceLine] = []
    public private(set) var userSpeaking = false
    /// The agent's words are playing.
    public private(set) var agentSpeaking = false
    public private(set) var isMuted = false
    public let agentName: String

    /// A finished user utterance (the prompt to send).
    @ObservationIgnored public var onUserSaid: (@MainActor (String) -> Void)?
    @ObservationIgnored public var onEnd: (@MainActor (VoiceCallFailure?) -> Void)?
    @ObservationIgnored private let link: any VoiceCallLink
    @ObservationIgnored private var config: AgentVoiceSessionConfig
    @ObservationIgnored private var listener: Task<Void, Never>?
    /// Text waiting to be read, oldest first.
    @ObservationIgnored private(set) var queue: [String] = []
    /// A reading was asked for and has not finished (`response.done`).
    @ObservationIgnored private var reading = false
    /// The text of the reading in flight, said again if the server refuses it.
    @ObservationIgnored private var inFlight: String?
    /// The server started the reading in flight (`response.created`).
    @ObservationIgnored private var inFlightStarted = false
    /// The reading in flight was refused once already: a second refusal drops it.
    @ObservationIgnored private var inFlightRetried = false
    /// A reading cut off by the user's voice: said again when what followed was
    /// only noise (a cough, a transcript of nothing); dropped when the user spoke.
    @ObservationIgnored private var interrupted: String?
    @ObservationIgnored private var retriedServerError = false
    @ObservationIgnored private var triedTranscriptionFallback = false

    public init(link: any VoiceCallLink, config: AgentVoiceSessionConfig) {
        self.link = link
        self.config = config
        agentName = config.agentName
    }

    public var isLive: Bool { phase == .live }
    public var hasEnded: Bool { if case .ended = phase { true } else { false } }
    public var failure: VoiceCallFailure? { if case let .ended(failure) = phase { failure } else { nil } }

    /// Connects and listens until voice mode ends.
    public func start() async {
        guard phase == .connecting, listener == nil else { return }
        let events = link.events
        listener = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
        while true {
            do {
                try await link.open(session: config.json)
                break
            } catch let failure as VoiceCallFailure {
                guard phase == .connecting else { return }
                if case .server = failure, !retriedServerError {
                    retriedServerError = true
                    continue
                }
                if case let .refused(message) = failure, !triedTranscriptionFallback,
                   message.localizedCaseInsensitiveContains("transcri") {
                    triedTranscriptionFallback = true
                    config.transcriptionModel = VoiceCallSessionConfig.fallbackTranscriptionModel
                    continue
                }
                finish(failure)
                return
            } catch {
                finish(.network(error.localizedDescription))
                return
            }
        }
        guard phase == .connecting else { return }
        link.setMicrophoneEnabled(!isMuted)
        phase = .live
        readNext()
    }

    /// Reads `text` aloud after what is already queued.
    public func relay(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hasEnded, !text.isEmpty else { return }
        queue.append(text)
        readNext()
    }

    public func setMuted(_ muted: Bool) {
        isMuted = muted
        link.setMicrophoneEnabled(!muted)
    }

    /// Stops the current reading and drops what is queued (a tap on the voice).
    public func skip() {
        guard isLive else { return }
        queue.removeAll()
        inFlight = nil
        interrupted = nil
        if reading { link.send(RealtimeClientEvent.responseCancel.data) }
        link.send(RealtimeClientEvent.outputAudioClear.data)
        agentSpeaking = false
    }

    public func end() { finish(nil) }

    public func abort(_ failure: VoiceCallFailure) { finish(failure) }

    // MARK: Events

    func handle(_ event: VoiceCallLinkEvent) {
        switch event {
        case let .message(data):
            guard let event = RealtimeServerEvent(data: data) else { return }
            handle(event)
        case let .audioInterrupted(began):
            link.setMicrophoneEnabled(!isMuted && !began)
        case .closed:
            if !hasEnded { finish(isLive ? .dropped : .network(String(localized: "The connection closed."))) }
        }
    }

    func handle(_ event: RealtimeServerEvent) {
        switch event {
        case let .speechStarted(itemID):
            userSpeaking = true
            if let itemID { upsert(itemID, role: .you, append: "", final: false) }
        case .speechStopped:
            userSpeaking = false
            readNext()
        case let .userTranscriptDelta(itemID, delta):
            upsert(itemID, role: .you, append: delta, final: false)
        case let .userTranscriptDone(itemID, transcript):
            let said = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isNoise(said) {
                // Never a prompt: transcription invents words from noise.
                lines.removeAll { $0.id == itemID }
                resumeInterrupted()
            } else {
                upsert(itemID, role: .you, replace: transcript, final: true)
                interrupted = nil
                onUserSaid?(said)
            }
        case let .userTranscriptFailed(itemID):
            lines.removeAll { $0.id == itemID && $0.text.isEmpty }
            resumeInterrupted()
        case let .assistantTranscriptDelta(itemID, delta):
            upsert(itemID, role: .agent, append: delta, final: false)
        case let .assistantTranscriptDone(itemID, transcript):
            upsert(itemID, role: .agent, replace: transcript, final: true)
        case .outputAudioStarted:
            agentSpeaking = true
        case .outputAudioStopped, .outputAudioCleared:
            agentSpeaking = false
        case let .responseDone(summary):
            reading = false
            // Cut off by the user's voice (not by Skip, which clears inFlight first).
            if summary.status == "cancelled", let text = inFlight { interrupted = text }
            inFlight = nil
            inFlightRetried = false
            inFlightStarted = false
            for index in lines.indices where lines[index].role == .agent && !lines[index].isFinal {
                lines[index].isFinal = true
            }
            readNext()
        case let .error(info):
            if info.code == "conversation_already_has_active_response" {
                // Our reading was refused: say it again once the other ends.
                reading = false
                if let text = inFlight { queue.insert(text, at: 0) }
                inFlight = nil
                inFlightStarted = false
            } else if reading, !inFlightStarted {
                // Any other refusal of our reading (rate limit, invalid input) gets no
                // response.done: free the line, retry the text once, go on with the queue.
                reading = false
                if let text = inFlight, !inFlightRetried {
                    queue.insert(text, at: 0)
                    inFlightRetried = true
                } else {
                    inFlightRetried = false
                }
                inFlight = nil
                readNext()
            } else if info.param?.contains("transcription") == true, !triedTranscriptionFallback {
                triedTranscriptionFallback = true
                link.send(RealtimeClientEvent.transcriptionModel(VoiceCallSessionConfig.fallbackTranscriptionModel).data)
            }
        case .responseCreated:
            if reading { inFlightStarted = true }
        case .sessionCreated, .sessionUpdated, .other:
            break
        }
    }

    /// Starts the next reading when nothing is being read and the user is not
    /// talking. Queued pieces go out as one reading, in order.
    private func readNext() {
        guard isLive, !reading, !userSpeaking, !queue.isEmpty else { return }
        let text = queue.joined(separator: "\n\n")
        queue.removeAll()
        reading = true
        inFlight = text
        inFlightStarted = false
        link.send(config.readEvent(text))
    }

    /// A reading cut off by noise goes back to the front of the queue.
    private func resumeInterrupted() {
        guard let text = interrupted else { return }
        interrupted = nil
        queue.insert(text, at: 0)
        readNext()
    }

    /// What transcription makes of noise, never sent as a prompt: nothing, a
    /// lone filler, or the phrases speech models invent from silence.
    static func isNoise(_ text: String) -> Bool {
        let folded = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard folded.contains(where: \.isLetter) else { return true }
        let invented: Set<String> = ["thank you", "thanks", "thanks for watching", "thank you for watching", "bye", "you",
                                     "uh", "um", "hmm", "mm", "ah", "oh", "okay bye", "subtitles by the amaraorg community"]
        return invented.contains(folded.replacingOccurrences(of: ".", with: ""))
    }

    private func upsert(_ itemID: String, role: AgentVoiceLine.Role, append: String? = nil, replace: String? = nil, final: Bool) {
        if let index = lines.lastIndex(where: { $0.id == itemID }) {
            if let replace, !replace.isEmpty { lines[index].text = replace }
            if let append { lines[index].text += append }
            lines[index].isFinal = final
        } else {
            lines.append(AgentVoiceLine(id: itemID, role: role, text: replace ?? append ?? "", isFinal: final))
            // Captions only need the recent past.
            if lines.count > 40 { lines.removeFirst(lines.count - 40) }
        }
    }

    private func finish(_ failure: VoiceCallFailure?) {
        guard !hasEnded else { return }
        phase = .ended(failure)
        userSpeaking = false
        agentSpeaking = false
        queue.removeAll()
        lines.removeAll { $0.text.isEmpty }
        listener?.cancel()
        listener = nil
        link.close()
        let onEnd = onEnd
        self.onEnd = nil
        onEnd?(failure)
    }
}

/// An agent session voice mode can talk to: a GUI agent chat or a terminal
/// agent. It reports the agent's new words and takes the user's prompts.
@MainActor
public protocol AgentVoiceSource: AnyObject {
    /// Stable per session (one voice mode per session).
    var voiceSourceID: String { get }
    var voiceAgentName: String { get }
    /// Starts reporting what the agent says from now on (never earlier
    /// history), already as speakable text. Runs until the token goes.
    func startVoiceFeed(_ speak: @escaping @MainActor (String) -> Void) -> AgentVoiceFeed
    /// Whether voice mode is offered now (a terminal only while an agent runs in it).
    var voiceAvailable: Bool { get }
    /// The user's words as a prompt to the agent. Returns nil when sent, or
    /// what to tell the user when it was not (it is read aloud).
    func sendVoicePrompt(_ text: String) -> String?
}

public extension AgentVoiceSource {
    var voiceAvailable: Bool { true }
}

/// Keeps a voice feed running; cancelling (or dropping) it stops the feed.
@MainActor
public final class AgentVoiceFeed {
    private var onCancel: (@MainActor () -> Void)?

    public init(onCancel: @escaping @MainActor () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        let onCancel = onCancel
        self.onCancel = nil
        onCancel?()
    }

    isolated deinit { cancel() }
}

/// One path from a composer's voice button to the app's voice mode. The
/// signed-in shell installs ``handler``; ``activeSourceID`` drives the
/// button's on state.
@MainActor
@Observable
public final class AgentVoiceLauncher {
    public static let shared = AgentVoiceLauncher()

    /// The session voice mode runs on, while it runs.
    public var activeSourceID: String?
    /// Starts voice mode on the source, or ends it when it runs there.
    public var handler: (@MainActor (any AgentVoiceSource) -> Void)?

    public init() {}

    public var isAvailable: Bool { handler != nil }

    public func toggle(_ source: any AgentVoiceSource) {
        handler?(source)
    }

    public func isActive(_ sourceID: String) -> Bool { activeSourceID == sourceID }
}
