import CmuxNextWakeups
public import Foundation
public import Observation

/// Sharing this Mac's screen with the Chief (docs/chief-screen-share.md): while on, one look per
/// ``interval``; a frame that changed becomes the current screen, and one whose text changed also
/// becomes a memory entry the Chief's brain turns into a note. Off means nothing runs: no timer,
/// no capture, no file written, and the current-screen files are gone.
///
/// Every entrypoint (the Home header toggle, the palette, the CLI and MCP) runs the
/// `chief.screenShare.*` actions, which call ``start()``, ``stop()`` and ``look()`` here.
///
/// ```swift
/// let share = ChiefScreenShare(capture: ChiefScreenHelperCapture(host: helper),
///                              journal: ChiefScreenJournal(directory: screenFolder))
/// share.start()
/// ```
///
/// The screen is read by the cmux Computer Use helper (``ChiefScreenHelperCapture``), so Screen
/// Recording is the helper's grant. While the helper is not running (starting, or relaunching after
/// the person granted Screen Recording) or Screen Recording is not allowed yet, sharing stays on and
/// checks again every ``interval``; it starts by itself once the helper answers and is allowed.
@MainActor
@Observable
public final class ChiefScreenShare {
    /// What sharing is doing.
    public enum State: Equatable, Sendable {
        /// Not sharing (the start of every launch).
        case off
        /// Checking Screen Recording before the first look.
        case starting
        /// Sharing: the screen is looked at every ``ChiefScreenShare/interval``.
        case sharing
        /// Screen Recording is not allowed for the helper: nothing is shared; checks again every
        /// ``ChiefScreenShare/interval`` and shares by itself once it is allowed.
        case needsPermission
        /// The helper that reads the screen is not running (starting, or relaunching after a grant):
        /// nothing is shared; checks again every ``ChiefScreenShare/interval``.
        case waitingForHelper
        /// The screen could not be read for another reason: nothing is shared.
        case failed
    }

    /// What sharing is doing.
    public private(set) var state: State = .off
    /// The last frame kept as the current screen this session, nil before the first.
    public private(set) var latest: ChiefScreenObservation?
    /// Memory entries written this session.
    public private(set) var remembered = 0

    /// True while starting, sharing or waiting to share: the header toggle shows on (a click stops it).
    public var isOn: Bool { state != .off && state != .failed }

    /// True while the screen is read (or about to be): the menu bar indicator shows.
    public var isReading: Bool { state == .starting || state == .sharing }

    /// How often the screen is looked at while sharing.
    public let interval: Duration

    private let capture: any ChiefScreenCapturing
    private let journal: any ChiefScreenJournaling
    private let now: @Sendable () -> Date
    private let timer: DemandTimer
    /// The Screen Recording check under way: at start, then every ``interval`` while waiting.
    private var starting: Task<Void, Never>?
    /// Whether the journal began this session (the first time the helper allowed a look).
    private var begun = false
    /// Whether this session asked the helper for Screen Recording (macOS prompts once).
    private var asked = false
    private var reading: Task<Void, Never>?
    private var previous: VoiceRoomFrameSignature?
    private var rememberedText: String?
    /// The last journal begin or end: the next one waits for it, so a quick stop and start keep their order.
    private var journalTail: Task<Void, Never>?
    /// Counts sharing sessions: work started in one session never writes into a later one.
    private var session = 0

    /// - Parameters:
    ///   - capture: Reads the screen.
    ///   - journal: Keeps what was seen.
    ///   - interval: How often the screen is looked at.
    ///   - clock: The cadence's clock; tests pass a manual one.
    ///   - now: The time stamped on a frame; tests pass a fixed one.
    public init(capture: any ChiefScreenCapturing, journal: any ChiefScreenJournaling, interval: Duration = .seconds(5),
                clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.capture = capture
        self.journal = journal
        self.interval = interval
        self.now = now
        timer = DemandTimer(owner: "chief.screenShare", clock: clock)
        // Off at every launch means nothing kept: a quit or a crash while sharing left the
        // current-screen files behind, and this deletes them before any start.
        // task-owner: one actor call at construction; later journal steps wait for it.
        journalTail = Task { await journal.endSharing() }
    }

    /// Starts sharing: asks for Screen Recording when needed, then looks at once and every
    /// ``interval``. Nothing when already on.
    public func start() {
        guard !isOn else { return }
        state = .starting
        previous = nil
        rememberedText = nil
        remembered = 0
        latest = nil
        begun = false
        asked = false
        session += 1
        check(after: journalTail)
    }

    /// What one Screen Recording check found.
    private enum Check: Equatable {
        case allowed
        case notAllowed
        case helperGone
        case failed
    }

    /// Asks the helper whether it may read the screen (and, the first time it may not, asks macOS for
    /// it), then shares, or waits and checks again after ``interval``.
    private func check(after tail: Task<Void, Never>? = nil) {
        guard starting == nil else { return }
        let capture = capture, journal = journal, mine = session, ask = !asked, begin = !begun
        starting = Task { [weak self] in
            await tail?.value
            let found = await Self.probe(capture, ask: ask)
            // A stop during the check cancels this task; its endSharing runs after it.
            if found == .allowed, begin, !Task.isCancelled { await journal.beginSharing() }
            guard let self, !Task.isCancelled, session == mine else { return }
            starting = nil
            switch found {
            case .allowed:
                begun = true
                state = .sharing
                read()
            case .notAllowed:
                asked = true
                wait(.needsPermission)
            case .helperGone:
                wait(.waitingForHelper)
            case .failed:
                end(.failed)
            }
        }
    }

    @concurrent
    private nonisolated static func probe(_ capture: any ChiefScreenCapturing, ask: Bool) async -> Check {
        do {
            if try await capture.isAllowed() { return .allowed }
            guard ask else { return .notAllowed }
            return try await capture.requestAccess() ? .allowed : .notAllowed
        } catch ChiefScreenCaptureInterruption.unavailable {
            return .helperGone
        } catch ChiefScreenCaptureInterruption.notAllowed {
            return .notAllowed
        } catch {
            return .failed
        }
    }

    /// Stays on without reading the screen, and checks again after ``interval``.
    private func wait(_ waiting: State) {
        state = waiting
        timer.schedule(after: interval) { @MainActor [weak self] in self?.check() }
    }

    /// Stops sharing: no more looks, and the current-screen files are deleted.
    public func stop() {
        guard state != .off else { return }
        end(.off)
    }

    /// Looks at the screen now, changed or not, and keeps it as the current screen and a memory entry.
    ///
    /// - Returns: What was seen.
    /// - Throws: ``ChiefScreenShareError``.
    public func look() async throws(ChiefScreenShareError) -> ChiefScreenObservation {
        guard state == .sharing else { throw .notSharing }
        let mine = session
        let frame: ChiefScreenFrame?
        do { frame = try await capture.capture(changedSince: nil) } catch { throw .unreadable }
        guard let frame, state == .sharing, session == mine else { throw .notSharing }
        previous = frame.signature
        rememberedText = frame.text
        guard let seen = await journal.record(frame, at: now(), remember: true), state == .sharing, session == mine else {
            throw .notSharing
        }
        remembered += 1
        latest = seen
        return seen
    }

    /// Waits for the work already started: a Screen Recording check, the look under way
    /// and the last journal step. A signal, never a delay: tests read the outcome after it.
    public func settled() async {
        await starting?.value
        await reading?.value
        await journalTail?.value
    }

    private func end(_ final: State) {
        timer.cancel()
        let start = starting
        start?.cancel()
        starting = nil
        reading?.cancel()
        reading = nil
        previous = nil
        session += 1
        state = final
        let journal = journal, tail = journalTail
        // task-owner: one actor call after the previous one and after a cancelled start's own step; it
        // deletes the current-screen files and the journal refuses later writes.
        journalTail = Task {
            await tail?.value
            await start?.value
            await journal.endSharing()
        }
    }

    private func schedule() {
        timer.schedule(after: interval) { @MainActor [weak self] in self?.read() }
    }

    private func read() {
        guard state == .sharing, reading == nil else { return }
        let capture = capture, journal = journal, previous = previous, mine = session
        reading = Task { [weak self] in
            let frame: ChiefScreenFrame?
            do { frame = try await capture.capture(changedSince: previous) } catch {
                guard let self, !Task.isCancelled, session == mine else { return }
                reading = nil
                // The helper relaunching (after a grant) or Screen Recording taken back: wait, then share again.
                switch error as? ChiefScreenCaptureInterruption {
                case .unavailable: return wait(.waitingForHelper)
                case .notAllowed: return wait(.needsPermission)
                case nil: return end(.failed)
                }
            }
            guard let self, !Task.isCancelled, state == .sharing, session == mine else { return }
            if let frame {
                self.previous = frame.signature
                let remember = frame.text != rememberedText
                // Claimed before the write, so a look meanwhile does not remember the same text again.
                if remember { rememberedText = frame.text }
                if let seen = await journal.record(frame, at: now(), remember: remember), !Task.isCancelled,
                   state == .sharing, session == mine {
                    latest = seen
                    if remember { remembered += 1 }
                }
            }
            guard !Task.isCancelled, state == .sharing, session == mine else { return }
            reading = nil
            schedule()
        }
    }
}
