import AppKit
public import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
public import Observation
import os

/// Restarts this app's local cmux-tui by itself when it is stale, at a quiet moment
/// (plans/cmux-next/server-updates-DESIGN.md rule 2). Stale: it runs another build than the bundled
/// one, or (build unknown) it lacks capabilities this app uses. Every handshake is checked
/// (``consider(_:bundledBuild:appCapabilities:)``), the first one at launch and each reconnect's,
/// with the bundled build read again each time (the app may have been updated while it runs).
///
/// The restart is the update handoff (`DaemonService.handOffForUpdate`): every terminal keeps
/// running and the new daemon adopts it; requests of the app's connection wait for the next daemon
/// (`DaemonConnection.quietHandoff`). What it could cut is a CLI or MCP call in flight, a chat or
/// a turn, so it waits for a quiet moment, all of:
/// - the person is idle: no input for ``Pacing/userIdle`` (or the app is in the background), and
///   no menu, drag or resize tracking runs;
/// - the owner is idle (`OwnerIdleProbe`, ``OwnerIdleProbe/Clients/reconnecting``): nobody types,
///   no chat or terminal UI is connected, and no CLI call (a local client without a kind counts
///   as one for its first ``OwnerIdleProbe/standardCallSeconds``).
/// While busy it tries again on owner events that can end the business (`IdleOwnerRestart.note`),
/// when the app goes to the background, and on a bounded deadline (``Pacing/retries`` times,
/// then events only). It never forces a restart: past ``Pacing/overdueAfter`` it keeps waiting and
/// lets the update toast show (``isOverdue``). At most once per daemon process and bundled build,
/// ``Pacing/perLaunch`` times in all.
///
/// Health check: after an accepted restart the next daemon must connect with the bundled build
/// within ``Pacing/healthTimeout``. If none connects, the reconnect is woken and it waits once
/// more; if one of another build connects, that one is restarted once more (at a quiet moment
/// again). A second failure sets ``healthFailure`` for a notice.
///
/// The update toast stays hidden while a restart waits (``suppressesNotice``); a refused or
/// impossible restart (an external binary, the toggle off), an overdue wait and a failed health
/// check leave it to the toast.
@MainActor
@Observable
public final class QuietDaemonUpdate {
    public struct Pacing: Sendable {
        /// Seconds without input before the person counts as idle.
        public var userIdle: Double
        /// The deadline between tries while busy, and how many such tries. No longer than
        /// ``OwnerIdleProbe/standardCallSeconds``: a client that ages out of a CLI call ends no event.
        public var retryInterval: Duration
        public var retries: Int
        /// How long a restart may wait for a quiet moment before the toast shows too.
        public var overdueAfter: Duration
        /// How long the next daemon has to connect with the bundled build.
        public var healthTimeout: Duration
        /// The most automatic restarts in one app launch.
        public var perLaunch: Int

        /// A minute of no input; a try a minute for half an hour (then events only, and the
        /// toast); 90 s for the next daemon (the old one has 60 s to exit, then `ensure`).
        public static let standard = Pacing(userIdle: 60, retryInterval: .seconds(60), retries: 30,
                                            overdueAfter: .seconds(30 * 60), healthTimeout: .seconds(90), perLaunch: 3)

        public init(userIdle: Double, retryInterval: Duration, retries: Int, overdueAfter: Duration,
                    healthTimeout: Duration, perLaunch: Int) {
            self.userIdle = userIdle
            self.retryInterval = retryInterval
            self.retries = retries
            self.overdueAfter = overdueAfter
            self.healthTimeout = healthTimeout
            self.perLaunch = perLaunch
        }
    }

    /// A restart is scheduled (or just accepted) for the current daemon.
    public private(set) var isWaiting = false
    /// The wait passed ``Pacing/overdueAfter`` with no quiet moment; it goes on.
    public private(set) var isOverdue = false
    /// Why the restarted daemon did not come back on the bundled build, after one retry.
    public private(set) var healthFailure: String?
    /// Restarts the daemon accepted this launch.
    public private(set) var restarts = 0

    /// The update toast of the local cmux-tui stays hidden: a restart waits and is not overdue.
    public var suppressesNotice: Bool { isWaiting && !isOverdue && healthFailure == nil }

    /// An accepted restart whose successor has not connected yet.
    private struct HealthCheck {
        var from: DaemonIdentity
        var bundled: String?
        /// The check already retried once: the next failure is reported.
        var retried: Bool
    }

    @ObservationIgnored private let pacing: Pacing
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let isEnabled: @Sendable () -> Bool
    @ObservationIgnored private let userIsIdle: @MainActor @Sendable () -> Bool
    @ObservationIgnored private let ownerIsIdle: @Sendable (DaemonIdentity) async -> Bool
    @ObservationIgnored private let restart: @Sendable (DaemonIdentity) async -> Bool
    @ObservationIgnored private let reconnect: @MainActor () -> Void
    /// Daemon process and bundled build pairs already scheduled (never twice).
    @ObservationIgnored private var tried: Set<String> = []
    @ObservationIgnored private var current: (key: String, restart: IdleOwnerRestart, events: AsyncStream<DaemonEvent>.Continuation)?
    @ObservationIgnored private var health: HealthCheck?
    /// The next accepted restart is a health check's retry.
    @ObservationIgnored private var retryingHealth = false
    @ObservationIgnored private let overdueTimer: DemandTimer
    @ObservationIgnored private let healthTimer: DemandTimer
    @ObservationIgnored private var resignObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.daemon")

    /// - Parameters:
    ///   - isEnabled: Read at each try (the Debug Settings toggle); off keeps it waiting, not restarting.
    ///   - userIsIdle: Whether the person is idle now.
    ///   - ownerIsIdle: Whether the daemon `identity` is idle now.
    ///   - restart: Hands the daemon off; true when it accepted.
    ///   - reconnect: Wakes the reconnect when no successor connected in time.
    public init(pacing: Pacing = .standard, clock: any Clock<Duration> = ContinuousClock(),
                isEnabled: @escaping @Sendable () -> Bool, userIsIdle: @escaping @MainActor @Sendable () -> Bool,
                ownerIsIdle: @escaping @Sendable (DaemonIdentity) async -> Bool,
                restart: @escaping @Sendable (DaemonIdentity) async -> Bool,
                reconnect: @escaping @MainActor () -> Void = {}) {
        self.pacing = pacing
        self.clock = clock
        self.isEnabled = isEnabled
        self.userIsIdle = userIsIdle
        self.ownerIsIdle = ownerIsIdle
        self.restart = restart
        self.reconnect = reconnect
        overdueTimer = DemandTimer(owner: "daemon.quietUpdate.overdue", clock: clock)
        healthTimer = DemandTimer(owner: "daemon.quietUpdate.health", clock: clock)
    }

    /// The local daemon of `daemon`: its owner probe and update handoff, the person's input
    /// idle time, and its owner events and the app going to the background as retries. It lives as
    /// long as the app (its subscription and observer are never removed).
    public convenience init(daemon: DaemonService, pacing: Pacing = .standard, isEnabled: @escaping @Sendable () -> Bool) {
        let userIdle = pacing.userIdle
        self.init(pacing: pacing, isEnabled: isEnabled, userIsIdle: { Self.personIsIdle(after: userIdle) },
                  ownerIsIdle: { [weak daemon] identity in
                      guard let connection = await daemon?.connection, await connection.identity?.pid == identity.pid else { return false }
                      return await OwnerIdleProbe(connection, clients: .reconnecting).isIdle()
                  },
                  restart: { [weak daemon] identity in await daemon?.handOffForUpdate(identity) ?? false },
                  reconnect: { [weak daemon] in daemon?.retryWake.fire() })
        daemon.store.sideEvents.subscribe { [weak self] event in self?.note(event) }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // task-owner: one hop to the main actor per deactivation; tryNow starts one probe
            Task { @MainActor in self?.tryNow() }
        }
    }

    /// Whether `identity` is stale against the bundled build: another build, or with either build
    /// unknown, a missing capability of `appCapabilities`. The same build is never stale (its
    /// restart would gain nothing).
    public nonisolated static func isStale(_ identity: DaemonIdentity, bundledBuild: String?,
                                           appCapabilities: Set<String>) -> Bool {
        if let running = identity.buildCommit, let bundledBuild { return running != bundledBuild }
        return !appCapabilities.subtracting(identity.capabilities).isEmpty
    }

    /// A handshake of the local daemon: checks a restart's successor, schedules its restart when
    /// stale, and drops the wait for a daemon that went away.
    public func consider(_ identity: DaemonIdentity, bundledBuild: String?, appCapabilities: Set<String>) {
        let stale = Self.isStale(identity, bundledBuild: bundledBuild, appCapabilities: appCapabilities)
        checkHealth(of: identity, stale: stale)
        if !stale { healthFailure = nil }
        let key = "\(identity.pid):\(identity.generation):\(bundledBuild ?? "?")"
        if current?.key == key { return }
        endWait()
        // After a failed health check only the person restarts it (the toast), until a daemon of the bundled build connects.
        guard stale, isEnabled(), healthFailure == nil, tried.count < pacing.perLaunch, tried.insert(key).inserted else {
            retryingHealth = false
            return
        }
        let userIsIdle = userIsIdle
        let ownerIsIdle = ownerIsIdle
        let isEnabled = isEnabled
        let restart = restart
        let restarter = IdleOwnerRestart(isIdle: {
            // Cheapest first: the person, then the owner (a few reads on the daemon).
            guard isEnabled(), await userIsIdle() else { return false }
            return await ownerIsIdle(identity)
        }, retry: IdleOwnerRestart.Retry(interval: pacing.retryInterval, count: pacing.retries, clock: clock)) { [weak self] in
            let accepted = await restart(identity)
            await self?.finished(key, accepted: accepted, identity: identity, bundled: bundledBuild)
            return accepted
        }
        // Owner events wake the waiting restart; the newest one is enough (each one probes the owner afresh).
        let (events, feed) = AsyncStream<DaemonEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
        current = (key, restarter, feed)
        isWaiting = true
        isOverdue = false
        // One bounded deadline, never a forced restart: the toast shows, the wait goes on.
        overdueTimer.schedule(after: pacing.overdueAfter) { @MainActor [weak self] in self?.markOverdue(key) }
        logger.info("cmux-tui \(identity.pid) is stale (build \(identity.buildCommit ?? "unknown", privacy: .public), bundled \(bundledBuild ?? "unknown", privacy: .public)); it restarts at a quiet moment")
        // task-owner: this wait; ends when the feed finishes (another daemon) or the restart is decided
        Task {
            if await restarter.attempt() != .waiting { return }
            for await event in events {
                if await restarter.note(event) != .waiting { break }
            }
        }
    }

    /// Tries at once (the app went to the background).
    public func tryNow() {
        guard let restarter = current?.restart else { return }
        // task-owner: one probe; the restart decides its outcome
        Task { await restarter.attempt() }
    }

    /// An event of the local daemon: a client left or a typing set changed may end the business.
    public func note(_ event: DaemonEvent) {
        guard IdleOwnerRestart.mayEndBusy(event) else { return }
        current?.events.yield(event)
    }

    private func finished(_ key: String, accepted: Bool, identity: DaemonIdentity, bundled: String?) {
        logger.info("cmux-tui \(identity.pid) quiet restart: \(accepted ? "started" : "refused", privacy: .public)")
        let retried = retryingHealth
        retryingHealth = false
        guard accepted else {
            // Refused: the toast may show.
            if current?.key == key { endWait() }
            if retried { failHealth("cmux-tui \(identity.pid) refused the second restart") }
            return
        }
        restarts += 1
        // The wait ends with the successor's handshake (`checkHealth`), or the health deadline.
        health = HealthCheck(from: identity, bundled: bundled, retried: retried)
        healthFailure = nil
        healthTimer.schedule(after: pacing.healthTimeout) { @MainActor [weak self] in self?.healthTimedOut() }
    }

    /// A handshake after an accepted restart: the successor of the bundled build passes; one of
    /// another build is restarted once more (by `consider`, it is stale), then reported.
    private func checkHealth(of identity: DaemonIdentity, stale: Bool) {
        guard let check = health, identity.pid != check.from.pid || identity.generation != check.from.generation else { return }
        health = nil
        healthTimer.cancel()
        guard stale else {
            logger.info("cmux-tui \(identity.pid) runs the bundled build after the quiet restart")
            return
        }
        if check.retried {
            failHealth("cmux-tui came back on build \(identity.buildCommit ?? "unknown"), not \(check.bundled ?? "the bundled one")")
        } else {
            retryingHealth = true
        }
    }

    /// No successor connected within the health timeout: wake the reconnect and wait once more,
    /// then report.
    private func healthTimedOut() {
        guard var check = health else { return }
        if check.retried {
            health = nil
            failHealth("the new cmux-tui did not connect")
            return
        }
        check.retried = true
        health = check
        logger.error("no cmux-tui connected after the quiet restart of \(check.from.pid); trying to reconnect")
        reconnect()
        healthTimer.schedule(after: pacing.healthTimeout) { @MainActor [weak self] in self?.healthTimedOut() }
    }

    private func failHealth(_ reason: String) {
        logger.error("cmux-tui quiet restart failed its health check: \(reason, privacy: .public)")
        healthFailure = reason
        isWaiting = false
    }

    private func markOverdue(_ key: String) {
        guard current?.key == key else { return }
        logger.info("cmux-tui restart found no quiet moment yet; the update toast shows while it waits")
        isOverdue = true
    }

    private func endWait() {
        overdueTimer.cancel()
        isOverdue = false
        guard let current else {
            if health == nil { isWaiting = false }
            return
        }
        self.current = nil
        // An accepted restart keeps the toast hidden until its successor's handshake.
        isWaiting = health != nil
        current.events.finish()
        let restarter = current.restart
        // task-owner: one hop to the restart's actor to stop its deadline
        Task { await restarter.stop() }
    }

    /// The person gives no input now: the app is in the background, or no input came for
    /// `seconds`; never inside a menu, drag or resize tracking loop.
    static func personIsIdle(after seconds: TimeInterval) -> Bool {
        // RunLoop.current is unavailable in async code; this runs on the main actor.
        guard RunLoop.main.currentMode == .default || RunLoop.main.currentMode == nil else { return false }
        guard NSApp?.isActive == true else { return true }
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) >= seconds
    }
}
