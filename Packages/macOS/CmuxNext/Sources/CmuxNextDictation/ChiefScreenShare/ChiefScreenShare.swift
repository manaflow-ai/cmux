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
/// let share = ChiefScreenShare(capture: ChiefScreenSystemCapture(),
///                              journal: ChiefScreenJournal(directory: screenFolder))
/// share.start()
/// ```
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
        /// Screen Recording is not allowed: nothing is shared.
        case needsPermission
        /// The screen could not be read any more (Screen Recording taken back): nothing is shared.
        case failed
    }

    /// What sharing is doing.
    public private(set) var state: State = .off
    /// The last frame kept as the current screen this session, nil before the first.
    public private(set) var latest: ChiefScreenObservation?
    /// Memory entries written this session.
    public private(set) var remembered = 0

    /// True while starting or sharing: the indicator and the header toggle show on.
    public var isOn: Bool { state == .starting || state == .sharing }

    /// How often the screen is looked at while sharing.
    public let interval: Duration

    private let capture: any ChiefScreenCapturing
    private let journal: any ChiefScreenJournaling
    private let now: @Sendable () -> Date
    private let timer: DemandTimer
    private var starting: Task<Void, Never>?
    private var reading: Task<Void, Never>?
    private var previous: VoiceRoomFrameSignature?
    private var rememberedText: String?
    /// The last journal begin or end: the next one waits for it, so a quick stop and start keep their order.
    private var journalTail: Task<Void, Never>?

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
        let capture = capture, journal = journal, tail = journalTail
        starting = Task { [weak self] in
            await tail?.value
            var allowed = await capture.isAllowed()
            if !allowed { allowed = await capture.requestAccess() }
            if allowed { await journal.beginSharing() }
            guard let self, !Task.isCancelled, state == .starting else { return }
            starting = nil
            guard allowed else { return end(.needsPermission) }
            state = .sharing
            read()
        }
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
        let frame: ChiefScreenFrame?
        do { frame = try await capture.capture(changedSince: nil) } catch { throw .unreadable }
        guard let frame, state == .sharing,
              let seen = await journal.record(frame, at: now(), remember: true) else { throw .notSharing }
        previous = frame.signature
        rememberedText = frame.text
        remembered += 1
        latest = seen
        return seen
    }

    /// Waits for the work already started: a start's Screen Recording check, the look under way
    /// and the last journal step. A signal, never a delay: tests read the outcome after it.
    public func settled() async {
        await starting?.value
        await reading?.value
        await journalTail?.value
    }

    private func end(_ final: State) {
        timer.cancel()
        starting?.cancel()
        starting = nil
        reading?.cancel()
        reading = nil
        previous = nil
        state = final
        let journal = journal, tail = journalTail
        // task-owner: one actor call after the previous one; it deletes the current-screen files and the journal refuses later writes.
        journalTail = Task {
            await tail?.value
            await journal.endSharing()
        }
    }

    private func schedule() {
        timer.schedule(after: interval) { @MainActor [weak self] in self?.read() }
    }

    private func read() {
        guard state == .sharing, reading == nil else { return }
        let capture = capture, journal = journal, previous = previous
        reading = Task { [weak self] in
            let frame: ChiefScreenFrame?
            do { frame = try await capture.capture(changedSince: previous) } catch {
                guard let self, !Task.isCancelled else { return }
                return end(.failed)
            }
            guard let self, !Task.isCancelled, state == .sharing else { return }
            if let frame {
                self.previous = frame.signature
                let remember = frame.text != rememberedText
                if let seen = await journal.record(frame, at: now(), remember: remember), !Task.isCancelled, state == .sharing {
                    latest = seen
                    if remember {
                        rememberedText = frame.text
                        remembered += 1
                    }
                }
            }
            guard !Task.isCancelled, state == .sharing else { return }
            reading = nil
            schedule()
        }
    }
}
