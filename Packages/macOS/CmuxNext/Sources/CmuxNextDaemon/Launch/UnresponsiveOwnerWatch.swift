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
        var replacing = false
    }

    private let state = Mutex(State())
    private let window: DemandTimer
    private let policy: Policy
    private let isEnabled: @Sendable () -> Bool
    private let replace: @Sendable () async -> Bool

    /// - Parameters:
    ///   - isEnabled: Read before each replace (the Debug Settings toggle).
    ///   - replace: Replaces the owner; true when the owner was replaced.
    public init(policy: Policy = .standard, clock: any Clock<Duration> = ContinuousClock(),
                isEnabled: @escaping @Sendable () -> Bool, replace: @escaping @Sendable () async -> Bool) {
        self.policy = policy
        self.isEnabled = isEnabled
        self.replace = replace
        window = DemandTimer(owner: "daemon.unresponsiveOwner.window", clock: clock)
    }

    /// Replaces started so far.
    public var replaceCount: Int { state.withLock { $0.replaces } }

    /// Records how one ensure ended; may start the replace.
    public func note(_ ensure: Ensure) {
        let started: UInt64? = state.withLock { state in
            switch ensure {
            case .stuck:
                state.streak += 1
                guard state.streak == 1 else { return nil }
                state.streakID &+= 1
                return state.streakID
            case .ready(let pid):
                state.owner = pid
                state.streak = 0
                state.windowPassed = false
                return nil
            case .busy, .failed:
                state.streak = 0
                state.windowPassed = false
                return nil
            }
        }
        guard case .stuck = ensure else {
            window.cancel()
            return
        }
        if let started {
            // One bounded deadline per streak, not a poll: it only marks the window as passed.
            window.schedule(after: policy.sustained) { [weak self] in self?.windowPassed(streak: started) }
        }
        evaluate()
    }

    private func windowPassed(streak: UInt64) {
        let current = state.withLock { state in
            guard state.streakID == streak, state.streak > 0 else { return false }
            state.windowPassed = true
            return true
        }
        if current { evaluate() }
    }

    private func evaluate() {
        guard isEnabled() else { return }
        let policy = policy
        let go = state.withLock { state in
            guard state.streak >= policy.stuckEnsures, state.windowPassed, !state.replacing,
                  state.replaces < policy.perLaunch, !state.replacedOwners.contains(state.owner) else { return false }
            state.replacing = true
            state.replacedOwners.insert(state.owner)
            state.replaces += 1
            return true
        }
        guard go else { return }
        let replace = replace
        // task-owner: one replace per stuck owner; it ends with `server ensure --replace-unresponsive`
        Task { [weak self] in
            _ = await replace()
            self?.state.withLock { $0.replacing = false }
        }
    }
}
