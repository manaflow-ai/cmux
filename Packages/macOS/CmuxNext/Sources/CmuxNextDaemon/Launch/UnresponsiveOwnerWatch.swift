import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// Restarts a session owner that stays alive but never answers, without the confirm of "Restart
/// cmux-tui" (cx-jniyz.1). The launcher's `server ensure` runs feed it (``EnsureOutcome``): once
/// ensures in a row failed the way a stuck owner makes them fail
/// (cmux-daemon-launch-core `classify_error`), at least ``Policy/stuckEnsures`` of them over at
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

    /// How one `server ensure` ended, for the watch (`{"kind": "ready"|"stuck"|"busy"|"failed", "pid"}`).
    public enum Ensure: Sendable, Equatable, Codable {
        /// It worked; `pid` is the owner it found or started.
        case ready(pid: Int32?)
        /// It failed the way a stuck owner makes it fail.
        case stuck
        /// The owner refused it at its connection limit: alive and answering, not stuck.
        case busy
        /// It failed another way (the owner did not start, another session...).
        case failed

        /// Reads an ensure's error (nil: it worked, starting or finding `pid`) through the launch rules
        /// (`classify_error`); a library that does not answer reads a plain failure, which ends a streak.
        public init(_ error: (any Error)?, pid: Int32?) {
            guard let error else {
                self = .ready(pid: pid)
                return
            }
            self = DaemonStartClassification(error)?.watch ?? .failed
        }

        private enum CodingKeys: String, CodingKey { case kind, pid }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .kind) {
            case "ready": self = .ready(pid: try container.decodeIfPresent(Int32.self, forKey: .pid))
            case "stuck": self = .stuck
            case "busy": self = .busy
            default: self = .failed
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .ready(let pid):
                try container.encode("ready", forKey: .kind)
                try container.encode(pid, forKey: .pid)
            case .stuck: try container.encode("stuck", forKey: .kind)
            case .busy: try container.encode("busy", forKey: .kind)
            case .failed: try container.encode("failed", forKey: .kind)
            }
        }
    }

    /// What the machine asks of the window's timer after a call.
    private struct Effects: Decodable {
        struct Schedule: Decodable { var streak: UInt64, afterMs: UInt64 }
        var schedule: Schedule?
        var cancel = false
        var evaluate = false

        private enum CodingKeys: String, CodingKey { case schedule, cancel, evaluate }

        init() {}

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schedule = try container.decodeIfPresent(Schedule.self, forKey: .schedule)
            cancel = try container.decodeIfPresent(Bool.self, forKey: .cancel) ?? false
            evaluate = try container.decodeIfPresent(Bool.self, forKey: .evaluate) ?? false
        }
    }

    /// A replace the machine started: its streak and the owner it replaces.
    private struct Start: Decodable { var streak: UInt64, owner: Int32? }

    /// The state machine (cmux-daemon-launch-core `watch`: the streak, the window, once per owner, the per-launch
    /// cap, the claim and its give-back). Every call holds this lock, and the window's timer is scheduled and
    /// cancelled under it, so an older outcome never cancels a newer streak's deadline (the timer's own lock is
    /// taken inside this one, never the other way).
    private let state: Mutex<DaemonLaunchWatchMachine>
    private let window: DemandTimer
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
        struct Rules: Encodable { var sustainedMs: UInt64, stuckEnsures: Int, perLaunch: Int }
        let rules = Rules(sustainedMs: DaemonLaunchRules.milliseconds(policy.sustained), stuckEnsures: max(0, policy.stuckEnsures), perLaunch: max(0, policy.perLaunch))
        state = Mutex(DaemonLaunchWatchMachine(policy: (try? JSONEncoder().encode(rules)) ?? Data()))
        self.isEnabled = isEnabled
        self.replace = replace
        window = DemandTimer(owner: "daemon.unresponsiveOwner.window", clock: clock)
    }

    /// Replaces started so far (a claim that says no gives its replace back).
    public var replaceCount: Int {
        state.withLock { $0.call("replace_count", Empty(), as: Int.self) } ?? 0
    }

    /// Whether the window's deadline is pending.
    public var isWaiting: Bool { window.isScheduled }

    /// Ends the watch for good: the deadline is cancelled and no replace is claimed after it
    /// (``DaemonRecovery/detach()``, when the service shuts its connection down).
    public func stop() {
        state.withLock { machine in
            apply(machine.call("stop", Empty(), as: Effects.self) ?? Self.cancelOnly)
            // The window ends with the watch whatever the machine said.
            window.cancel()
        }
    }

    /// Records how one ensure ended; may start the replace. The deadline (``Policy/sustained``,
    /// one-shot) is pending only during a stuck streak with the toggle on.
    public func note(_ ensure: Ensure) {
        struct Request: Encodable { var ensure: Ensure, enabled: Bool }
        let enabled = isEnabled()
        let evaluate = state.withLock { machine -> Bool in
            // A machine that does not answer ends the streak: nothing is replaced on a guess.
            let effects = machine.call("note", Request(ensure: ensure, enabled: enabled), as: Effects.self) ?? Self.cancelOnly
            apply(effects)
            return effects.evaluate
        }
        if evaluate { self.evaluate() }
    }

    private struct Empty: Encodable {}
    private struct Streak: Encodable { var streak: UInt64, owner: Int32?, enabled: Bool }
    private struct Enabled: Encodable { var enabled: Bool }

    private static var cancelOnly: Effects {
        var effects = Effects()
        effects.cancel = true
        return effects
    }

    /// Runs the timer side of `effects` (under the state lock).
    private func apply(_ effects: Effects) {
        if effects.cancel { window.cancel() }
        if let schedule = effects.schedule {
            let streak = schedule.streak
            // One bounded deadline per streak, not a poll: it only marks the window as passed.
            window.schedule(after: .milliseconds(Int64(clamping: schedule.afterMs))) { [weak self] in self?.windowPassed(streak: streak) }
        }
    }

    private func windowPassed(streak: UInt64) {
        let enabled = isEnabled()
        let evaluate = state.withLock { machine -> Bool in
            let effects = machine.call("window_passed", Streak(streak: streak, owner: nil, enabled: enabled), as: Effects.self) ?? Effects()
            apply(effects)
            return effects.evaluate
        }
        if evaluate { self.evaluate() }
    }

    private func evaluate() {
        let enabled = isEnabled()
        guard enabled else { return }
        let started = state.withLock { machine -> Start? in
            machine.call("evaluate", Enabled(enabled: enabled), as: Start?.self) ?? nil
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
        state.withLock { machine in
            _ = machine.call("finish", Streak(streak: streak, owner: owner, enabled: false), as: Effects.self)
        }
    }

    /// Whether the replace queued for `streak` may still run: the toggle is on, the watch was not
    /// stopped, and the same owner is still in the same stuck streak. When not, the replace is
    /// given back (its count and its owner), so that owner can be replaced on a later streak; a
    /// claim that finds the toggle off also ends the streak. A machine that does not answer says no.
    nonisolated private func claim(_ streak: UInt64, owner: Int32?) -> Bool {
        struct Reply: Decodable {
            var yes: Bool
            var cancel: Bool?
        }
        let enabled = isEnabled()
        return state.withLock { machine in
            guard let reply = machine.call("claim", Streak(streak: streak, owner: owner, enabled: enabled), as: Reply.self) else {
                return false
            }
            if reply.cancel == true { window.cancel() }
            return reply.yes
        }
    }
}
