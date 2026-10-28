import CmuxNextWakeups
public import Foundation
public import Observation

/// One open Voice Room on this Mac: listens to the mic all the time and sends each finished
/// sentence to the room, and every ``screenInterval`` sends the screen's text when it changed. The room's pause (anyone in it can press it) stops both until the room resumes.
///
/// Speech and screen text are read on device; only text goes to the room. Lines go out one at a
/// time in order. A session restarts the dictation engine when it ends by itself, and gives up
/// (``State/failed(_:)``) when it ends three times in a row with no words, or is denied.
///
/// ```swift
/// let session = VoiceRoomSession(dictation: { DictationSession() },
///                                poster: VoiceRoomHTTPPoster(address: address),
///                                events: VoiceRoomWebSocketEvents(address: address),
///                                screen: VoiceRoomScreenReader(frames: framesFolder))
/// session.start()
/// ```
@MainActor
@Observable
public final class VoiceRoomSession {
    /// What the session is doing.
    public enum State: Equatable, Sendable {
        /// Not started, or stopped.
        case off
        /// Listening and reading the screen.
        case listening
        /// The room is paused: nothing is heard or read until it resumes.
        case paused
        /// It stopped: the reason, for the person.
        case failed(Failure)
    }

    /// Why a session stopped by itself.
    public enum Failure: Equatable, Sendable {
        /// The microphone or speech recognition permission is denied.
        case denied(DictationPermission)
        /// The dictation engine keeps ending with no words.
        case dictationStopped
        /// Another mic user (a composer's dictation) took the microphone.
        case micTaken
    }

    /// What the session is doing.
    public private(set) var state: State = .off
    /// Lines the room took.
    public private(set) var linesSent = 0
    /// The last send's error, nil after a send that worked.
    public private(set) var lastSendError: String?

    /// How often the screen is looked at.
    public let screenInterval: Duration

    private let makeDictation: () -> any VoiceRoomDictating
    private let poster: any VoiceRoomPosting
    private let events: any VoiceRoomEventSource
    private let screen: (any VoiceRoomScreenReading)?
    private var dictation: (any VoiceRoomDictating)?
    private var splitter = VoiceRoomLineSplitter()
    private var emptyEnds = 0
    private var heardSinceStart = false
    private var outbox: AsyncStream<VoiceRoomLine>.Continuation?
    private var tasks: [Task<Void, Never>] = []
    private let screenTimer: DemandTimer
    private var screenRead: Task<Void, Never>?
    private var previousFrame: VoiceRoomFrameSignature?

    /// Lines kept while the room is slow to answer; older ones are dropped past this.
    static let outboxCapacity = 256

    /// - Parameters:
    ///   - dictation: Makes the speech engine, once per ``start()``.
    ///   - poster: Sends lines to the room.
    ///   - events: The room's pause state.
    ///   - screen: Reads the screen; nil hears the mic only.
    ///   - screenInterval: How often the screen is looked at.
    ///   - clock: The screen cadence's clock; tests pass a manual one.
    public init(dictation: @escaping () -> any VoiceRoomDictating, poster: any VoiceRoomPosting,
                events: any VoiceRoomEventSource, screen: (any VoiceRoomScreenReading)?,
                screenInterval: Duration = .seconds(5), clock: any Clock<Duration> = ContinuousClock()) {
        makeDictation = dictation
        self.poster = poster
        self.events = events
        self.screen = screen
        self.screenInterval = screenInterval
        screenTimer = DemandTimer(owner: "voiceRoom.screen", clock: clock)
    }

    /// True while listening or paused by the room.
    public var isOpen: Bool { state == .listening || state == .paused }

    /// Starts listening and reading the screen; nothing when already open.
    public func start() {
        guard !isOpen else { return }
        state = .listening
        emptyEnds = 0
        // A room that stops answering must not grow memory without bound: keep the newest lines.
        let (stream, continuation) = AsyncStream.makeStream(of: VoiceRoomLine.self, bufferingPolicy: .bufferingNewest(Self.outboxCapacity))
        outbox = continuation
        tasks = [sender(stream), pauseWatcher()]
        scheduleScreenRead()
        listen()
    }

    /// Stops everything; the words of a sentence not yet finished are dropped.
    public func stop() {
        end(.off)
    }

    /// Another mic user took the microphone (``DictationMicrophoneClaims``).
    public func yieldMicrophone() {
        guard isOpen else { return }
        end(.failed(.micTaken))
    }

    private func end(_ final: State) {
        screenTimer.cancel()
        screenRead?.cancel()
        screenRead = nil
        previousFrame = nil
        tasks.forEach { $0.cancel() }
        tasks = []
        outbox?.finish()
        outbox = nil
        silence()
        state = final
    }

    private func listen() {
        let engine = dictation ?? makeDictation()
        dictation = engine
        heardSinceStart = false
        engine.onUpdate = { [weak self] update in self?.heard(update) }
        engine.start()
    }

    private func silence() {
        dictation?.onUpdate = nil
        dictation?.cancel()
        splitter = VoiceRoomLineSplitter()
    }

    private func heard(_ update: DictationUpdate) {
        guard state == .listening else { return }
        switch update.phase {
        case .listening, .finalizing:
            let lines = splitter.feed(update.text, level: update.level)
            if !lines.isEmpty { heardSinceStart = true }
            lines.forEach(send)
        case .idle:
            let lines = splitter.finish(update.text)
            if !lines.isEmpty || heardSinceStart { emptyEnds = 0 } else { emptyEnds += 1 }
            lines.forEach(send)
            guard emptyEnds < 3 else { return end(.failed(.dictationStopped)) }
            listen()
        case .denied(let permission):
            end(.failed(.denied(permission)))
        case .failed:
            emptyEnds += 1
            guard emptyEnds < 3 else { return end(.failed(.dictationStopped)) }
            listen()
        case .starting:
            break
        }
    }

    private func send(_ line: VoiceRoomLine) {
        outbox?.yield(line)
    }

    private func sender(_ lines: AsyncStream<VoiceRoomLine>) -> Task<Void, Never> {
        let poster = poster
        return Task { [weak self] in
            for await line in lines {
                do {
                    let paused = try await poster.post(line)
                    self?.sent(paused: paused)
                } catch {
                    self?.lastSendError = String(describing: error)
                }
            }
        }
    }

    private func sent(paused: Bool) {
        lastSendError = nil
        if paused { roomPaused(true) } else { linesSent += 1 }
    }

    private func pauseWatcher() -> Task<Void, Never> {
        let events = events
        return Task { [weak self] in
            for await paused in events.pauses() {
                self?.roomPaused(paused)
            }
        }
    }

    private func roomPaused(_ paused: Bool) {
        if paused, state == .listening {
            state = .paused
            silence()
        } else if !paused, state == .paused {
            state = .listening
            emptyEnds = 0
            listen()
        }
    }

    /// The next screen look, one ``DemandTimer`` shot per interval while the session is open.
    private func scheduleScreenRead() {
        guard screen != nil else { return }
        screenTimer.schedule(after: screenInterval) { @MainActor [weak self] in self?.readScreen() }
    }

    private func readScreen() {
        guard isOpen, let screen else { return }
        guard state == .listening else { return scheduleScreenRead() }
        let previous = previousFrame
        screenRead = Task { [weak self] in
            let sample = try? await screen.read(changedSince: previous)
            guard let self, !Task.isCancelled else { return }
            if let sample {
                previousFrame = sample.signature
                if !sample.text.isEmpty { send(VoiceRoomLine(kind: .screen, text: sample.text)) }
            }
            screenRead = nil
            scheduleScreenRead()
        }
    }
}
