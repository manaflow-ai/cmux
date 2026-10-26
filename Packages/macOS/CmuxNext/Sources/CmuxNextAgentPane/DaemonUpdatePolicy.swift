import CmuxNextCompat
public import CmuxNextDesign
public import CmuxNextWakeups
public import Foundation
import os

/// After the app updates, brings other machines' daemons to the app's own build, in the
/// background. One policy for every kind of machine (``DaemonUpdateTarget``), and one instance per
/// app (``shared``) that every source feeds with ``offer(_:)``:
///
/// - the trigger: a target whose build is another commit than the app's bundled build (a dirty
///   bundled build never pushes); an ``DaemonUpdateTarget/urgent`` target also with no known build.
///   Never a move back: a target on a build of a later day, or on a build with local changes
///   (someone's own), is left alone;
/// - no wait for a quiet moment: a target is updated mid-turn from the first ask, since a machine
///   where agents always work never has an idle moment, and the restarted daemon resumes what it
///   interrupted (Leo: "OUR SHIT IS HARDLY EVER GOING TO GO IDLE. IT JUST WONT. YOU'LL JUST HAVE TO
///   ACCEPT IT BREAKING AT SOME POINT BUT IT RESUMES WHATEVER IT INTERRUPTED. END OF STORY FOR THE
///   DAEMON UPDATE."). One that cannot update now (unreachable, another update running) is asked
///   again with backoff (2 minutes, doubling, at most 30 minutes apart) and is left for the next
///   launch after 6 hours;
/// - one target at a time across every source, urgent targets first;
/// - one attempt per target and build: a final outcome is kept in ``DaemonUpdateLedger`` across
///   launches, so a target that rolled back or failed is not tried again until the next build; one
///   left for the next launch (no binary, still busy after 6 hours) is not tried again in this run;
/// - each target's state on ``DaemonUpdateBoard``, and one notice per failed target and build;
/// - off with the Debug Settings toggle `agent.updatePeers`, read before every step.
public actor DaemonUpdatePolicy {
    nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon-update")

    public nonisolated struct Dependencies: Sendable {
        /// The app's bundled build (the bundled acpmux's `--version` build), read when the queue
        /// starts to drain.
        public var bundledBuild: @Sendable () async -> String?
        /// The machines ``run()`` offers.
        public var targets: @Sendable () async -> [any DaemonUpdateTarget]
        /// `agent.updatePeers`.
        public var enabled: @Sendable () -> Bool
        /// Each target's state as it changes (``DaemonUpdateBoard``).
        public var report: @Sendable (DaemonUpdateEvent) async -> Void
        /// Where ``DaemonUpdateLedger`` lives.
        public var directory: URL
        public var clock: any Clock<Duration>
        public var busyBackoff = Backoff(initial: .seconds(120), maximum: .seconds(1800), multiplier: 2, jitter: 0)
        /// A target busy for this long is updated mid-turn
        /// (``DaemonUpdateTarget/update(to:whileBusy:)``); before, only at a quiet moment. Zero,
        /// the default (Leo's order above): every update runs mid-turn from the first ask.
        public var updateBusyAfter: Duration = .zero
        /// A target that answers busy this long, also to updates while busy, is left for the next
        /// launch.
        public var giveUpAfter: Duration = .seconds(6 * 3600)

        public init(bundledBuild: @escaping @Sendable () async -> String?,
                    targets: @escaping @Sendable () async -> [any DaemonUpdateTarget] = DaemonUpdatePolicy.noTargets,
                    enabled: @escaping @Sendable () -> Bool = { AgentPaneTunables.updatePeersAutomatically.value },
                    report: @escaping @Sendable (DaemonUpdateEvent) async -> Void = DaemonUpdatePolicy.showOnBoard,
                    directory: URL = DaemonUpdatePolicy.defaultDirectory, clock: any Clock<Duration> = ContinuousClock()) {
            self.bundledBuild = bundledBuild
            self.targets = targets
            self.enabled = enabled
            self.report = report
            self.directory = directory
            self.clock = clock
        }
    }

    // Named functions, not async closure literals, as default arguments (crash ratchet, cx-bsue);
    // public, since the public init's defaults name them.
    /// No targets: ``Dependencies/targets`` by default.
    @Sendable public nonisolated static func noTargets() async -> [any DaemonUpdateTarget] { [] }

    /// Applies `event` to ``DaemonUpdateBoard/shared``: ``Dependencies/report`` by default.
    @Sendable public nonisolated static func showOnBoard(_ event: DaemonUpdateEvent) async {
        await MainActor.run { DaemonUpdateBoard.shared.apply(event) }
    }

    /// `daemon-update` in this build's own Application Support directory (``BuildIdentity``).
    public nonisolated static let defaultDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return BuildIdentity(bundle: .main).appSupport(support.appendingPathComponent("cmux", isDirectory: true))
            .appendingPathComponent("daemon-update", isDirectory: true)
    }()

    // lint:allow one policy per app process: every machine's update goes through its one queue, one at a time
    public nonisolated static let shared = DaemonUpdatePolicy(Dependencies(bundledBuild: { await DaemonUpdatePolicy.bundledAcpmuxBuild() }))

    /// The bundled acpmux's build (the binary `acpmux host update` pushes); nil when the app has none.
    nonisolated static func bundledAcpmuxBuild() async -> String? {
        let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        guard let acpmux = AcpmuxEnvironment.resolve(build: nil, bundledBinDirectory: bin) else { return nil }
        return await bundledBuild(of: acpmux.executable)
    }

    /// The build `executable --version` names; nil when it does not answer within `bound` (it is
    /// stopped then: SIGTERM, SIGKILL 2 s later) or names none. Bounded, since the queue waits on
    /// it before its first target.
    nonisolated static func bundledBuild(of executable: URL, within bound: Duration = .seconds(10)) async -> String? {
        guard let outcome = try? await AsyncProcess().run(ProcessRequest(executable, ["--version"], timeout: bound)) else { return nil }
        return AcpmuxVersionHandoff.build(fromVersion: outcome.text)
    }

    private let dependencies: Dependencies
    /// Time since the policy was made, on its clock.
    private let elapsed: @Sendable () -> Duration
    /// The targets offered and not yet done, the one updating now excluded.
    private var queue: [Pending] = []
    /// The id of the target whose update runs now.
    private var running: String?
    /// The loop that drains ``queue``; nil while it is empty.
    private var drain: Task<Void, Never>?
    /// The drain's backoff wait; ``offer(_:)`` cuts it short.
    private var sleeper: Task<Void, Never>?
    /// Targets done in this run (a final outcome, also one the ledger could not keep) or left for the
    /// next launch (no binary, still busy after 6 hours): id to bundled hash.
    private var settled: [String: String] = [:]

    public init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
        elapsed = Self.stopwatch(dependencies.clock)
    }

    private nonisolated static func stopwatch<C: Clock>(_ clock: C) -> @Sendable () -> Duration where C.Duration == Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }

    /// One target waiting for its update; `due` and `firstBusy` count on ``elapsed``.
    private nonisolated struct Pending {
        var target: any DaemonUpdateTarget
        var urgent: Bool
        var due: Duration
        var backoff: Backoff
        var firstBusy: Duration?
    }

    /// Queues `target` and returns at once; the queue drains in the background, one target at a
    /// time. A target already queued or updating (same ``DaemonUpdateTarget/id``) is not queued
    /// twice: a queued one takes this value and keeps its backoff, and an urgent offer moves it to
    /// the front. Whether it needs the update is read when its turn comes. Nothing while
    /// `agent.updatePeers` is off.
    public func offer(_ target: any DaemonUpdateTarget) async {
        enqueue(target, urgent: await target.urgent)
    }

    /// Offers every target of ``Dependencies/targets`` and returns when the queue is empty: each
    /// target done, left for the next launch, or the toggle turned off.
    public func run() async {
        let deps = dependencies
        guard deps.enabled() else { return Self.logger.info("daemon update off (agent.updatePeers)") }
        var offered: [(target: any DaemonUpdateTarget, urgent: Bool)] = []
        for target in await deps.targets() {
            offered.append((target, await target.urgent))
        }
        for each in offered {
            enqueue(each.target, urgent: each.urgent)
        }
        await drained()
    }

    /// Returns when no target is queued or updating.
    public func drained() async {
        while let drain {
            await drain.value
        }
    }

    private func enqueue(_ target: any DaemonUpdateTarget, urgent: Bool) {
        guard dependencies.enabled(), running != target.id else { return }
        let now = elapsed()
        if let index = queue.firstIndex(where: { $0.target.id == target.id }) {
            queue[index].target = target
            if urgent, !queue[index].urgent {
                queue[index].urgent = true
                queue[index].due = min(queue[index].due, now)
                sleeper?.cancel()
            }
        } else {
            queue.append(Pending(target: target, urgent: urgent, due: now, backoff: dependencies.busyBackoff))
            sleeper?.cancel()
        }
        // Also for a target already queued: a queued target always has a drain.
        guard drain == nil else { return }
        // task-owner: this policy; drains the queue one target at a time and ends when it is empty
        drain = Task { await self.drainQueue() }
    }

    private func drainQueue() async {
        let deps = dependencies
        guard deps.enabled(), let local = DaemonBuildCommit(await deps.bundledBuild()), !local.dirty else {
            Self.logger.info("daemon update skipped: off, or the bundled build is unknown or has local changes")
            queue.removeAll()
            drain = nil
            return
        }
        var ledger = DaemonUpdateLedger.read(deps.directory, build: local.hash)
        while let index = nextIndex() {
            let wait = queue[index].due - elapsed()
            if wait > .zero {
                await nap(wait)
                continue
            }
            guard deps.enabled() else {
                Self.logger.info("daemon update stopped: agent.updatePeers turned off")
                let retried = queue.filter { $0.firstBusy != nil }
                queue.removeAll()
                for each in retried {
                    await deps.report(DaemonUpdateEvent(each.target, .cleared))
                }
                // The toggle may have come back on during the reports, and a target offered
                // since sits in the queue with no other drain to run it: read the queue again.
                continue
            }
            let pending = queue.remove(at: index)
            running = pending.target.id
            if let again = await attempt(pending, local: local, ledger: &ledger) {
                queue.append(again)
            }
            running = nil
        }
        drain = nil
    }

    /// The next target: an urgent one that is due, else the one due first.
    private func nextIndex() -> Int? {
        let now = elapsed()
        let due = queue.indices.filter { queue[$0].due <= now }
        if let urgent = due.first(where: { queue[$0].urgent }) { return urgent }
        return due.min { queue[$0].due < queue[$1].due } ?? queue.indices.min { queue[$0].due < queue[$1].due }
    }

    /// Waits `wait`, or less when ``offer(_:)`` brings a new target.
    private func nap(_ wait: Duration) async {
        let clock = dependencies.clock
        // task-owner: drainQueue awaits it; enqueue cancels it so a new target need not wait out a busy one's backoff
        let sleep = Task {
            // wakeup-allow: the backoff of a busy machine, at most 30 minutes apart and only for 6 hours
            _ = try? await clock.sleep(for: wait)
        }
        sleeper = sleep
        await sleep.value
        sleeper = nil
    }

    /// One update of `pending` if it still needs one; returns it when it was busy and waits again.
    private func attempt(_ pending: Pending, local: DaemonBuildCommit, ledger: inout DaemonUpdateLedger) async -> Pending? {
        let deps = dependencies
        let target = pending.target
        guard !ledger.attempted(target.id), settled[target.id] != local.hash else { return await dropped(pending) }
        // Read at its turn: the machine may have gone, or reached this build meanwhile.
        let urgent = await target.urgent
        let current = DaemonBuildCommit(await target.currentBuild())
        if let current, local.sameCommit(current.hash) { return await dropped(pending) }
        if let current, current.dirty || current.isNewer(than: local) {
            Self.logger.info("\(target.displayName, privacy: .public) runs \(current.hash, privacy: .public)\(current.dirty ? " with local changes" : ", newer than this app's build", privacy: .public); left alone")
            return await dropped(pending)
        }
        guard current != nil || urgent else { return await dropped(pending) }
        // Busy for ``Dependencies/updateBusyAfter`` or longer (at once when it is zero): this update
        // does not wait for an idle moment.
        let asked = elapsed()
        let whileBusy = asked - (pending.firstBusy ?? asked) >= deps.updateBusyAfter
        await deps.report(DaemonUpdateEvent(target, .updating))
        let outcome = await target.update(to: local, whileBusy: whileBusy)
        Self.logger.info("\(target.displayName, privacy: .public) to \(local.hash, privacy: .public)\(whileBusy ? " while busy" : "", privacy: .public): \(String(describing: outcome), privacy: .public)")
        if outcome == .busy {
            var again = pending
            let now = elapsed()
            let since = again.firstBusy ?? now
            again.firstBusy = since
            let delay = again.backoff.next()
            guard now + delay - since <= deps.giveUpAfter else {
                Self.logger.info("\(target.displayName, privacy: .public) stayed busy; left for the next launch")
                settled[target.id] = local.hash
                // Not "will try again": no retry comes in this run.
                await deps.report(DaemonUpdateEvent(target, .cleared))
                return nil
            }
            await deps.report(DaemonUpdateEvent(target, .retrying))
            // The first update while busy runs at the cap, not after a backoff that passes it.
            let cap = since + deps.updateBusyAfter
            again.due = now < cap ? min(now + delay, cap) : now + delay
            return again
        }
        // Not tried again in this run whatever the ledger write does: a ledger that was not written
        // would let the next drain retry a rollback.
        settled[target.id] = local.hash
        if let recorded = Self.recorded(outcome) {
            ledger.targets[target.id] = recorded
            do { try ledger.write(deps.directory) } catch {
                Self.logger.error("daemon update ledger not written: \(String(describing: error), privacy: .public)")
            }
        }
        await deps.report(Self.event(target, outcome, local: local))
        return nil
    }

    /// Drops `pending`, which no longer needs an update; one asked again before leaves the board,
    /// since no retry comes.
    private func dropped(_ pending: Pending) async -> Pending? {
        if pending.firstBusy != nil { await dependencies.report(DaemonUpdateEvent(pending.target, .cleared)) }
        return nil
    }

    /// What the ledger keeps for `outcome`: every final outcome. `busy`, `needsBinary` and
    /// `handledElsewhere` are not final: the next launch asks again.
    nonisolated static func recorded(_ outcome: DaemonUpdateOutcome) -> String? {
        switch outcome {
        case .updated: "updated"
        case .current: "current"
        case .rolledBack: "rolledBack"
        case .failed: "failed"
        case .busy, .needsBinary, .handledElsewhere: nil
        }
    }

    /// The board's state after a final outcome, with the build it was about. Only a recorded
    /// failure notifies: it is recorded once per target and build, so its notice shows once.
    nonisolated static func event(_ target: any DaemonUpdateTarget, _ outcome: DaemonUpdateOutcome,
                                  local: DaemonBuildCommit) -> DaemonUpdateEvent {
        let build = local.hash
        return switch outcome {
        case .updated(let reported): DaemonUpdateEvent(target, .updated(build: reported ?? build), build: build)
        case .current: DaemonUpdateEvent(target, .updated(build: build), build: build)
        case .busy: DaemonUpdateEvent(target, .retrying)
        case .needsBinary(let triple): DaemonUpdateEvent(target, .failed(reason: "no build for \(triple)", rolledBack: false), build: build)
        case .rolledBack(let reason): DaemonUpdateEvent(target, .failed(reason: reason, rolledBack: true), notify: true, build: build)
        case .handledElsewhere: DaemonUpdateEvent(target, .cleared)
        case .failed(let reason): DaemonUpdateEvent(target, .failed(reason: reason, rolledBack: false), notify: true, build: build)
        }
    }
}
