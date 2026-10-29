import Foundation
import Observation

/// What the audio/event connection reports to the call.
public enum VoiceCallLinkEvent: Sendable, Equatable {
    /// One `oai-events` data channel message.
    case message(Data)
    /// Another app took the audio session (a phone call, Siri) or gave it back.
    case audioInterrupted(Bool)
    /// The connection ended without the user hanging up.
    case closed
}

/// The connection under a call: on the phone, WebRTC (microphone and
/// speaker as media, events on the `oai-events` data channel); in tests, a fake.
@MainActor
public protocol VoiceCallLink: AnyObject {
    var events: AsyncStream<VoiceCallLinkEvent> { get }
    /// Sets up audio and connects with `session`; returns once the event
    /// channel is open. Throws ``VoiceCallFailure``.
    func open(session: Data) async throws
    func send(_ data: Data)
    func setMicrophoneEnabled(_ enabled: Bool)
    func setSpeakerOutput(_ speaker: Bool)
    func close()
}

/// One line on the call screen.
public struct VoiceCallLine: Identifiable, Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        /// What the user said (transcribed) or typed.
        case you
        /// What Chief's voice said.
        case chief
        /// Something Chief did: sent a message, looked something up, a new reply.
        case activity
    }

    public let id: String
    public var role: Role
    public var text: String
    /// False while the words are still coming in.
    public var isFinal: Bool
}

/// A live voice call with Chief over the Realtime API.
///
/// Owns the call's state (phase, who is speaking, the captions) and runs
/// the model's function calls against the ``VoiceCallToolbox``. Everything is
/// event-driven: link events in, client events out; no timers.
@MainActor
@Observable
public final class VoiceCallSession: Identifiable {
    public enum Phase: Sendable, Equatable {
        case connecting
        case live
        case ended(VoiceCallFailure?)
    }

    public nonisolated let id = UUID()
    public private(set) var phase: Phase = .connecting
    public private(set) var lines: [VoiceCallLine] = []
    /// The user is talking (server VAD).
    public private(set) var userSpeaking = false
    /// Chief's audio is playing.
    public private(set) var chiefSpeaking = false
    /// Chief is working on an answer: a response is being generated or a tool runs.
    public private(set) var chiefThinking = false
    public private(set) var isMuted = false
    public private(set) var usesSpeaker = true
    /// Another app holds the audio (a phone call): the microphone is off until it ends.
    public private(set) var onHold = false
    public private(set) var connectedAt: Date?
    public private(set) var endedAt: Date?
    public let modelID: String

    @ObservationIgnored private let link: any VoiceCallLink
    @ObservationIgnored private let toolbox: any VoiceCallToolbox
    @ObservationIgnored private var config: VoiceCallSessionConfig
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Called once when the call ends (the controller brings a minimized call's failure back).
    @ObservationIgnored public var onEnd: (@MainActor (VoiceCallFailure?) -> Void)?
    @ObservationIgnored private var listener: Task<Void, Never>?
    /// A response is being generated (between `response.created` and `response.done`).
    @ObservationIgnored private var activeResponse = false
    /// `response.create`s sent and not yet started: `response.done` of a
    /// cancelled response must not read as "idle" while one is on its way.
    @ObservationIgnored private var requestedResponses = 0
    /// A response.create was refused because one was already running: ask again when it ends.
    @ObservationIgnored private var needsFollowUp = false
    private var responding: Bool { activeResponse || requestedResponses > 0 }
    /// Chief messages that arrived while the model was busy, spoken next.
    @ObservationIgnored private var pendingNotes: [String] = []
    /// end_call ran: hang up once Chief's goodbye has played.
    @ObservationIgnored private var hangUpAfterSpeech = false
    @ObservationIgnored private var triedTranscriptionFallback = false

    public init(link: any VoiceCallLink, toolbox: any VoiceCallToolbox, config: VoiceCallSessionConfig,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.link = link
        self.toolbox = toolbox
        self.config = config
        self.now = now
        modelID = config.model
    }

    public var isLive: Bool { phase == .live }
    public var hasEnded: Bool { if case .ended = phase { true } else { false } }

    /// Connects and listens until the call ends.
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
                if case let .refused(message) = failure, !triedTranscriptionFallback,
                   message.localizedCaseInsensitiveContains("transcri") {
                    // The transcription model was refused at setup: connect
                    // again (the link opens afresh) with the older one.
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
        // Hung up while connecting: finish already closed the link.
        guard phase == .connecting else { return }
        // Mute set while connecting holds on the connection that came up.
        link.setMicrophoneEnabled(!isMuted && !onHold)
        phase = .live
        connectedAt = now()
    }

    /// The user hung up.
    public func hangUp() {
        finish(nil)
    }

    /// Ends the call before it connects (the microphone is off for cmux).
    public func abort(_ failure: VoiceCallFailure) {
        finish(failure)
    }

    public func setMuted(_ muted: Bool) {
        isMuted = muted
        link.setMicrophoneEnabled(!muted && !onHold)
    }

    public func setSpeaker(_ speaker: Bool) {
        usesSpeaker = speaker
        link.setSpeakerOutput(speaker)
    }

    /// Stops Chief mid-sentence (a tap on Chief's avatar).
    public func interrupt() {
        guard isLive, chiefSpeaking || responding else { return }
        if responding { link.send(RealtimeClientEvent.responseCancel.data) }
        link.send(RealtimeClientEvent.outputAudioClear.data)
        chiefSpeaking = false
    }

    /// A typed message (the keyboard button): a user turn, answered at once.
    public func send(text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLive, !text.isEmpty else { return }
        if responding || chiefSpeaking { interrupt() }
        lines.append(VoiceCallLine(id: "typed-\(UUID().uuidString)", role: .you, text: text, isFinal: true))
        link.send(RealtimeClientEvent.userText(text).data)
        requestResponse()
    }

    /// A new message from Chief's agent: Chief's voice tells the user about
    /// it as soon as it is not talking or listening.
    public func chiefReplied(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLive, !text.isEmpty else { return }
        lines.append(VoiceCallLine(id: "reply-\(UUID().uuidString)", role: .activity,
                                   text: String(localized: "New message from Chief"), isFinal: true))
        pendingNotes.append(text)
        flushNotes()
    }

    // MARK: Events

    func handle(_ event: VoiceCallLinkEvent) {
        switch event {
        case let .message(data):
            guard let event = RealtimeServerEvent(data: data) else { return }
            handle(event)
        case let .audioInterrupted(began):
            onHold = began
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
        case let .userTranscriptDelta(itemID, delta):
            upsert(itemID, role: .you, append: delta, final: false)
        case let .userTranscriptDone(itemID, transcript):
            upsert(itemID, role: .you, replace: transcript, final: true)
        case let .userTranscriptFailed(itemID):
            // Nothing to show for speech that didn't transcribe.
            lines.removeAll { $0.id == itemID && $0.text.isEmpty }
        case .responseCreated:
            requestedResponses = max(0, requestedResponses - 1)
            activeResponse = true
            chiefThinking = true
        case let .assistantTranscriptDelta(itemID, delta):
            chiefThinking = false
            upsert(itemID, role: .chief, append: delta, final: false)
        case let .assistantTranscriptDone(itemID, transcript):
            upsert(itemID, role: .chief, replace: transcript, final: true)
        case .outputAudioStarted:
            chiefSpeaking = true
            chiefThinking = false
        case .outputAudioStopped, .outputAudioCleared:
            chiefSpeaking = false
            if hangUpAfterSpeech, !responding { finish(nil) }
        case let .responseDone(summary):
            responseDone(summary)
        case let .error(info):
            if info.code == "conversation_already_has_active_response" {
                // Our response.create raced the server's own (after the user spoke): what we
                // added is in the conversation; ask again once that response ends.
                requestedResponses = max(0, requestedResponses - 1)
                needsFollowUp = true
            } else if info.param?.contains("transcription") == true, !triedTranscriptionFallback {
                triedTranscriptionFallback = true
                link.send(RealtimeClientEvent.transcriptionModel(VoiceCallSessionConfig.fallbackTranscriptionModel).data)
            }
        case .sessionCreated, .sessionUpdated, .other:
            break
        }
    }

    private func responseDone(_ summary: RealtimeResponseSummary) {
        activeResponse = false
        // Drop caption lines left open by a cut-off response.
        for index in lines.indices where lines[index].role == .chief && !lines[index].isFinal {
            lines[index].isFinal = true
        }
        if summary.status == "failed" {
            chiefThinking = false
            let reason = summary.failureCode == "insufficient_quota"
                ? String(localized: "Your OpenAI account is out of credit.")
                : summary.failureMessage ?? String(localized: "Chief couldn't answer.")
            lines.append(VoiceCallLine(id: "failed-\(UUID().uuidString)", role: .activity, text: reason, isFinal: true))
        }
        guard !summary.functionCalls.isEmpty else {
            if !responding { chiefThinking = false }
            if hangUpAfterSpeech, !chiefSpeaking { finish(nil); return }
            if needsFollowUp, !responding, !userSpeaking, pendingNotes.isEmpty {
                needsFollowUp = false
                requestResponse()
                return
            }
            flushNotes()
            return
        }
        chiefThinking = true
        let calls = summary.functionCalls
        Task { [weak self] in await self?.run(calls) }
    }

    private func run(_ calls: [RealtimeFunctionCall]) async {
        var needsResponse = false
        for call in calls {
            guard isLive else { return }
            let result: VoiceCallToolResult
            switch VoiceCallTool.Name(rawValue: call.name) {
            case .sendToChief:
                let message = call.argumentObject["message"] as? String ?? ""
                result = await toolbox.sendToChief(message)
                needsResponse = true
            case .readChiefMessages:
                let count = (call.argumentObject["count"] as? Int).map { min(max($0, 1), 20) } ?? 6
                result = toolbox.readChiefMessages(count: count)
                needsResponse = true
            case .listWorkspaces:
                result = toolbox.listWorkspaces()
                needsResponse = true
            case .listNeedsAttention:
                result = toolbox.listNeedsAttention()
                needsResponse = true
            case .endCall:
                hangUpAfterSpeech = true
                result = VoiceCallToolResult(object: ["ok": true])
            case nil:
                result = VoiceCallToolResult(object: ["error": "unknown function \(call.name)"])
                needsResponse = true
            }
            if let activity = result.activity {
                lines.append(VoiceCallLine(id: "tool-\(call.callID)", role: .activity, text: activity, isFinal: true))
            }
            guard isLive else { return }
            link.send(RealtimeClientEvent.functionOutput(callID: call.callID, output: result.output).data)
        }
        guard isLive else { return }
        if hangUpAfterSpeech, !needsResponse {
            chiefThinking = false
            if !chiefSpeaking { finish(nil) }
            return
        }
        requestResponse()
    }

    private func requestResponse() {
        link.send(RealtimeClientEvent.responseCreate.data)
        requestedResponses += 1
        chiefThinking = true
    }

    private func flushNotes() {
        guard isLive, !responding, !userSpeaking, !pendingNotes.isEmpty else { return }
        let notes = pendingNotes
        pendingNotes.removeAll()
        for note in notes {
            link.send(RealtimeClientEvent.systemNote("Chief replied: \(note)").data)
        }
        needsFollowUp = false
        requestResponse()
    }

    private func upsert(_ itemID: String, role: VoiceCallLine.Role, append: String? = nil, replace: String? = nil, final: Bool) {
        if let index = lines.lastIndex(where: { $0.id == itemID }) {
            if let replace, !replace.isEmpty { lines[index].text = replace }
            if let append { lines[index].text += append }
            lines[index].isFinal = final
        } else {
            lines.append(VoiceCallLine(id: itemID, role: role, text: replace ?? append ?? "", isFinal: final))
        }
    }

    private func finish(_ failure: VoiceCallFailure?) {
        guard !hasEnded else { return }
        phase = .ended(failure)
        endedAt = now()
        userSpeaking = false
        chiefSpeaking = false
        chiefThinking = false
        lines.removeAll { $0.text.isEmpty }
        listener?.cancel()
        listener = nil
        link.close()
        let onEnd = onEnd
        self.onEnd = nil
        onEnd?(failure)
    }

    /// Whether the session config asked for the newer transcription model (tests).
    var transcriptionModel: String { config.transcriptionModel }
}
