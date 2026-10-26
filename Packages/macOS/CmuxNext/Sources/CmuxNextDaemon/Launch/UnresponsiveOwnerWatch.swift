import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// Restarts a session owner that stays alive but never answers, without the confirm of "Restart
/// cmux-tui" (cx-jniyz.1). The launcher's `server ensure` runs feed it (``EnsureOutcome``): once
/// ensures in a row failed the way a stuck owner makes them fail
/// (``DaemonLauncher/isStuckOwnerFailure(_:)``), at least ``Policy/stuckEnsures`` of them over at
/// least ``Policy/sustained``, it runs `replace` (`server ensure --replace-unresponsive`), at most
/// once per owner process and ``Policy/perLaunch`` times in all. Any other ensure ends the streak:
/// one that worked, one that failed another way, and one refused at the connection limit
/// (`server.busy`: that owner answers, it is busy, not stuck). The terminal hosts are separate
/// processes: they survive the replace and the next owner adopts them.
public final class UnresponsiveOwnerWatch: Sendable {
    public struct Policy: Sendable, Equatable {
        /// How long ensures must keep failing as stuck before the replace.
        public var sustained: Duration
        /// How many stuck ensures in a row the replace needs.
        public var stuckEnsures: Int
        /// The most replaces in one app launch (an owner that wedges again at every start).
        public var perLaunch: Int

        /// 30 s and two stuck ensures: past the reconnect's first attempts, and each stuck ensure
        /// already waited its own bound (the restore bound, or no answer to `identify` for 10 s).
        public static let standard = Policy(sustained: .seconds(30), stuckEnsures: 2, perLaunch: 3)

        public init(sustained: Duration, stuckEnsures: Int, perLaunch: Int) {
            self.sustained = sustained
            self.stuckEnsures = stuckEnsures
            self.perLaunch = perLaunch
        }
    }

    /// How one `server ensure` ended, for the watch.
    public enum Ensure: Sendable, Equatable {
        /// It worked; `pid` is the owner it found or started.
        case ready(pid: Int32?)
        /// It failed the way a stuck owner makes it fail.
        case stuck
        /// The owner refused it at its connection limit: alive and answering, not stuck.
        case busy
        /// It failed another way (the owner did not start, another session...).
        case failed

        /// Reads an ensure's error (nil: it worked, starting or finding `pid`).
        public init(_ error: (any Error)?, pid: Int32?) {
            guard let error else {
                self = .ready(pid: pid)
                return
            }
            if case .launchFailed(let detail)? = error as? DaemonError, detail.contains("\"server.busy\"") {
                self = .busy
            } else {
                self = DaemonLauncher.isStuckOwnerFailure(error) ? .stuck : .failed
            }
        }
    }

    private struct State {
        /// Stuck ensures in a row, and which streak it is (a timer of an ended streak does nothing).
        var streak = 0
        var streakID: UInt64 = 0
        var windowPassed = false
        /// The owner the last ensure that worked found; nil before any.
        var owner: Int32?
        var replacedOwners: Set<Int32?> = []
        var replaces = 0
        /// The streak whose replace is queued or running; nil when none is.
        var replacing: UInt64?
        /// The last streak whose claim said yes (its replace ran: it counts, whatever its result).
        var claimed: UInt64?
        /// ``stop()`` ran (the service shut its connection down): nothing is replaced any more.
        var stopped = false
    }

    private let state = Mutex(State())
    private let window: DemandTimer
    private let policy: Policy
    private let isEnabled: @Sendable () -> Bool
    private let replace: @Sendable (_ claim: @escaping @Sendable () -> Bool) async -> Bool

    /// - Parameters:
    ///   - isEnabled: The Debug Settings toggle, read at each stuck ensure, when the window passes
    ///     and at the claim. Off at any of those ends the streak and its deadline. The window
    ///     measures the owner, not the toggle: turned off and on again between two reads, the
    ///     owner stayed stuck the whole time, so the streak goes on; the replace itself runs only
    ///     when the claim reads the toggle on, on the executor that replaces.
    ///   - replace: Replaces the owner; true when the owner was replaced. It must call `claim`
    ///     right before it replaces, on the executor that replaces, and replace only when `claim`
    ///     says yes: the replace was queued before it ran, and by then the toggle may be off, an
    ///     ensure may have worked, or the person's own Restart may have replaced the owner. A
    ///     replace that ends without a yes (refused before its claim, or the claim said no) is
    ///     given back: it counts neither toward ``Policy/perLaunch`` nor as that owner's one.
    public init(policy: Policy = .standard, clock: any Clock<Duration> = ContinuousClock(),
                isEnabled: @escaping @Sendable () -> Bool,
                replace: @escaping @Sendable (_ claim: @escaping @Sendable () -> Bool) async -> Bool) {
        self.policy = policy
        self.isEnabled = isEnabled
        self.replace = replace
        window = DemandTimer(owner: "daemon.unresponsiveOwner.window", clock: clock)
    }

    /// Replaces started so far (a claim that says no gives its replace back).
    public var replaceCount: Int { state.withLock { $0.replaces } }

    /// Whether the window's deadline is pending.
    public var isWaiting: Bool { window.isScheduled }

    /// Ends the watch for good: the deadline is cancelled and no replace is claimed after it
    /// (``DaemonRecovery/detach()``, when the service shuts its connection down).
    public func stop() {
        state.withLock { state in
            state.stopped = true
            state.streak = 0
            state.windowPassed = false
            window.cancel()
        }
    }

    /// Records how one ensure ended; may start the replace. The deadline is scheduled and
    /// cancelled under the state lock, so an older outcome never cancels a newer streak's
    /// deadline (the timer's own lock is taken inside this one, never the other way).
    ///
    /// The deadline (``Policy/sustained``, one-shot) is pending only during a stuck streak with
    /// the toggle on: an ensure that is not stuck cancels it, a stuck one with the toggle off ends
    /// the streak and cancels it, ``stop()`` cancels it, and when it fires with the toggle off it
    /// ends the streak.
    public func note(_ ensure: Ensure) {
        let enabled = isEnabled()
        let policy = policy
        let evaluate = state.withLock { state -> Bool in
            guard !state.stopped else { return false }
            switch ensure {
            case .stuck where enabled:
                state.streak += 1
                if state.streak == 1 {
                    state.streakID &+= 1
                    state.windowPassed = false
                    let started = state.streakID
                    // One bounded deadline per streak, not a poll: it only marks the window as passed.
                    window.schedule(after: policy.sustained) { [weak self] in self?.windowPassed(streak: started) }
                }
                return true
            case .stuck:
                Self.endStreak(&state, window: window)
                return false
            case .ready(let pid):
                state.owner = pid
                Self.endStreak(&state, window: window)
                return false
            case .busy, .failed:
                Self.endStreak(&state, window: window)
                return false
            }
        }
        if evaluate { self.evaluate() }
    }

    private static func endStreak(_ state: inout State, window: DemandTimer) {
        state.streak = 0
        state.windowPassed = false
        window.cancel()
    }

    private func windowPassed(streak: UInt64) {
        let enabled = isEnabled()
        let current = state.withLock { state in
            guard !state.stopped, state.streakID == streak, state.streak > 0 else { return false }
            guard enabled else {
                state.streak = 0
                return false
            }
            state.windowPassed = true
            return true
        }
        if current { evaluate() }
    }

    /// Whether the current streak is due for a replace now.
    private func due(_ state: State) -> Bool {
        !state.stopped && state.streak >= policy.stuckEnsures && state.windowPassed
            && state.replaces < policy.perLaunch && !state.replacedOwners.contains(state.owner)
    }

    private func evaluate() {
        guard isEnabled() else { return }
        let started: (streak: UInt64, owner: Int32?)? = state.withLock { state in
            guard state.replacing == nil, due(state) else { return nil }
            state.replacing = state.streakID
            state.replacedOwners.insert(state.owner)
            state.replaces += 1
            return (state.streakID, state.owner)
        }
        guard let started else { return }
        let replace = replace
        let claim: @Sendable () -> Bool = { [weak self] in self?.claim(started.streak, owner: started.owner) ?? false }
        // task-owner: one replace per stuck owner; it ends with `server ensure --replace-unresponsive` or a claim that says no
        Task { [weak self] in
            _ = await replace(claim)
            self?.finish(started.streak, owner: started.owner)
        }
    }

    /// The replace for `streak` ended. One that never got a yes from its claim (the recovery
    /// refused it first: the person's Restart was running) is given back like a claim that says
    /// no, so the same owner, still stuck, is replaced at a later stuck ensure.
    private func finish(_ streak: UInt64, owner: Int32?) {
        state.withLock { state in
            guard state.replacing == streak else { return }
            if state.claimed != streak {
                state.replaces -= 1
                state.replacedOwners.remove(owner)
            }
            state.replacing = nil
        }
    }

    /// Whether the replace queued for `streak` may still run: the toggle is on, the watch was not
    /// stopped, and the same owner is still in the same stuck streak. When not, the replace is
    /// given back (its count and its owner), so that owner can be replaced on a later streak; a
    /// claim that finds the toggle off also ends the streak.
    nonisolated private func claim(_ streak: UInt64, owner: Int32?) -> Bool {
        let enabled = isEnabled()
        return state.withLock { state in
            let current = enabled && !state.stopped && state.replacing == streak && state.streakID == streak
                && state.streak >= policy.stuckEnsures && state.windowPassed && state.owner == owner
            if current {
                state.claimed = streak
            } else if state.replacing == streak {
                state.replaces -= 1
                state.replacedOwners.remove(owner)
                state.replacing = nil
            }
            if !enabled { Self.endStreak(&state, window: window) }
            return current
        }
    }
}
