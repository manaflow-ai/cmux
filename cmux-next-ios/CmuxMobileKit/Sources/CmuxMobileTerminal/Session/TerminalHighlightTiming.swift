import Foundation

/// Runs `work` on the main actor `delay` seconds from now (0: the next main-queue turn).
/// The highlights' timers take one so their tests can run them by hand.
public typealias TerminalMainScheduler = @MainActor (_ delay: Double, _ work: @escaping @MainActor () -> Void) -> Void

public enum TerminalMainQueue {
    /// ``TerminalMainScheduler`` on the main dispatch queue.
    public static func schedule(_ delay: Double, _ work: @escaping @MainActor () -> Void) {
        if delay <= 0 {
            DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
        }
    }
}

/// How long a followed highlight's text may be off the screen before the highlight ends
/// (Leo, 2026-11-24: "sometimes the highlights in terminal just float and dont move when i
/// scroll?"). A screen drawn in more than one batch (cleared, then drawn again) can lack the
/// text for a moment: the highlight hides at once and ends only when the text is still gone
/// ``grace`` later, judged by the clock or by the look again scheduled for then, whichever
/// comes first, so a timer that fires a hair early still ends it.
@MainActor
public final class TerminalLostTextGrace {
    public static let grace: Double = 0.5

    public enum Step: Equatable {
        /// The text just went missing: hide the highlight (the look again is scheduled).
        case hide
        /// Still missing, within the grace: keep it hidden.
        case wait
        /// Still missing past the grace: end the highlight.
        case end
    }

    private let now: () -> Double
    private let schedule: TerminalMainScheduler
    private var since: Double?
    /// Bumped on every loss and reset: a look again scheduled for an older loss does nothing.
    private var generation = 0
    private var lookingAgain = false

    public init(now: @escaping () -> Double, schedule: @escaping TerminalMainScheduler) {
        self.now = now
        self.schedule = schedule
    }

    /// The text is missing now (the highlight is hidden).
    public var isLost: Bool { since != nil }

    /// The text is on the screen (or the highlight changed): any loss is over. True when
    /// the text was missing.
    @discardableResult
    public func reset() -> Bool {
        let was = since != nil
        since = nil
        generation += 1
        return was
    }

    /// The text is not on the screen. The first time this schedules `lookAgain` for when
    /// the grace is over; when it calls back here, the answer is ``Step/end``.
    public func lost(lookAgain: @escaping @MainActor () -> Void) -> Step {
        let time = now()
        guard let since else {
            since = time
            generation += 1
            let mine = generation
            schedule(Self.grace) { [weak self] in
                guard let self, generation == mine, isLost else { return }
                lookingAgain = true
                defer { lookingAgain = false }
                lookAgain()
            }
            return .hide
        }
        return lookingAgain || time - since >= Self.grace ? .end : .wait
    }
}

/// One run of a piece of work per main-queue turn, however many times it is asked for in
/// that turn (a full-screen app's redraw arrives in many batches; find searches the screen
/// once for them all).
@MainActor
public final class TerminalTurnCoalescer {
    private let schedule: TerminalMainScheduler
    private var pending = false

    public init(schedule: @escaping TerminalMainScheduler) {
        self.schedule = schedule
    }

    /// Runs `work` on the next turn unless a run is already due; true when this asked for it.
    @discardableResult
    public func request(_ work: @escaping @MainActor () -> Void) -> Bool {
        guard !pending else { return false }
        pending = true
        schedule(0) { [weak self] in
            self?.pending = false
            work()
        }
        return true
    }
}
