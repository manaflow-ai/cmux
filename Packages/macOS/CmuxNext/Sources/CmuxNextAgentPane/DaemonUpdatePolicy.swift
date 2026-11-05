import CmuxNextCompat
public import CmuxNextDesign
public import CmuxNextWakeups
public import Foundation
import os

/// After the app updates, brings other machines' daemons to the app's own build, in the
/// background. One policy for every kind of machine (``DaemonUpdateTarget``), and one instance per
/// app (``DaemonUpdates/policy``, made once by `AppServices`) that every source feeds with ``offer(_:)``:
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
///   launch after 6 hours; an unreachable one shows as offline, never as a failure, and is asked
///   again at once when it connects (its next offer), also after those 6 hours;
/// - one target at a time across every source, urgent targets first;
/// - one attempt per target and build: a final outcome is kept in ``DaemonUpdateLedger`` across
///   launches, so a target that rolled back or failed is not tried again until the next build; one
///   left for the next launch (no binary, still busy after 6 hours) is not tried again in this run;
/// - a target that cannot take a build in place (``DaemonUpdateOutcome/unsupported(reason:)``) is
///   no failure: it shows on the board with no notice, and is not tried again, on this build or a
///   later one, while it reports the build it ran then (``DaemonUpdateLedger/cannotUpdate``);
/// - each target's state on ``DaemonUpdateBoard``, which groups the failures into one notice;
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
        /// Each target's state as it changes (the app's ``DaemonUpdateBoard``).
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
                    report: @escaping @Sendable (DaemonUpdateEvent) async -> Void,
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

    /// `daemon-update` in this build's own Application Support directory (``BuildIdentity``).
    public nonisolated static let defaultDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return BuildIdentity(bundle: .main).appSupport(support.appendingPathComponent("cmux", isDirectory: true))
            .appendingPathComponent("daemon-update", isDirectory: true)
    }()

    /// The bundled acpmux's build (the binary `acpmux host update` pushes); nil when the app has none.
    nonisolated static func bundledAcpmuxBuild() async -> String? {
        let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        guard let acpmux = AcpmuxEnvironment.resolve(build: nil, bundledBinDirectory: bin) else { return nil }
        return await bundledBuild(of: acpmux.executable)
    }

    /// The build `executable --version` names; nil when it does not answer within `bound` on
    /// `clock` (it is stopped then: SIGTERM, SIGKILL 2 s later) or names none. Bounded, since the
    /// queue waits on it before its first target. Tests pass a manual `clock`.
    nonisolated static func bundledBuild(of executable: URL, within bound: Duration = .seconds(10),
                                         clock: any Clock<Duration> = ContinuousClock()) async -> String? {
        guard let outcome = try? await AsyncProcess(clock: clock).run(ProcessRequest(executable, ["--version"], timeout: bound)) else {
            return nil
        }
        return AcpmuxVersionHandoff.build(fromVersion: outcome.text)
    }

    private let dependencies: Dependencies
    /// Time since the policy was made, on its clock.
    private let elapsed: @Sendable () -> Duration
    /// The targets offered and not yet done, the one updating now excluded.
    private var queue: [Pending] = []
    /// The id of the target whose update runs now.
    private var running: String?
    /// The id of the target inside its `update(to:whileBusy:)` call now: a turn ``updateNow``
    /// joins without marking it, since that update answers the refusal (review of #29497).
    private var updating: String?
    /// The loop that drains ``queue``; nil while it is empty.
    private var drain: Task<Void, Never>?
    /// The drain's backoff wait; ``offer(_:)`` cuts it short.
    private var sleeper: Task<Void, Never>?
    /// Targets done in this run (a final outcome, also one the ledger could not keep) or left for the
    /// next launch (no binary, still busy after 6 hours): id to bundled hash.
    private var settled: [String: String] = [:]
    /// The last value offered of each target, by id: what ``retry(_:)`` queues again.
    private var offered: [String: any DaemonUpdateTarget] = [:]
    /// Targets the person asked to update again (``retry(_:)``) whose turn has not come: neither the
    /// ledger nor this run's memory holds them back.
    private var retried: Set<String> = []
    /// Targets whose line says offline after their entry left the queue (still unreachable after
    /// 6 hours, or disconnected while offline): their next offer clears that line when they need
    /// no update.
    private var offlineShown: Set<String> = []
    /// Callers of ``updateNow(_:)`` waiting for a turn of their target to end, by target id: each
    /// stream is finished when that turn ends (any outcome) or the queue drops the target.
    private var turnWaiters: [String: [UUID: AsyncStream<Void>.Continuation]] = [:]

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
        /// Its last answer was ``DaemonUpdateOutcome/unreachable``: its board line says offline.
        var offline = false
    }

    /// Queues `target` and returns at once; the queue drains in the background, one target at a
    /// time. A target already queued or updating (same ``DaemonUpdateTarget/id``) is not queued
    /// twice: a queued one takes this value and keeps its backoff, and an urgent offer moves it to
    /// the front. Whether it needs the update is read when its turn comes. Nothing while
    /// `agent.updatePeers` is off.
    public func offer(_ target: any DaemonUpdateTarget) async {
        enqueue(target, urgent: await target.urgent)
    }

    /// The person's "Update" on a machine of Settings > Updates' "Other machines" row: target `id`
    /// (offered in this run) is queued again and updated at its turn, also when it could not update
    /// in place before or its update failed on this build. False when no target of that id was
    /// offered in this run, or `agent.updatePeers` is off.
    @discardableResult
    public func retry(_ id: String) -> Bool {
        guard dependencies.enabled(), let target = offered[id] else { return false }
        retried.insert(id)
        // Its turn runs now: a click that came before the update itself ran is taken once the
        // turn ends (``drainQueue()``); one the update ran after is spent by it.
        if running != id { enqueue(target, urgent: false) }
        return true
    }

    /// A chat start that the machine's older daemon refused (a fresh Cloud machine whose image
    /// baked a cmux-tui from before cmux#29107): `target` is updated at the front of the queue now,
    /// as the person's Update click would be (neither the ledger nor this run's memory holds it
    /// back), and this returns once that turn ended, whatever its outcome, so the caller can start
    /// again on the daemon it left. A turn of `target` already running is joined, never run twice.
    /// Returns at once while `agent.updatePeers` is off, and when the calling task is cancelled.
    public func updateNow(_ target: any DaemonUpdateTarget) async {
        guard dependencies.enabled() else { return }
        let id = target.id
        // Its update already runs: that update answers this refusal, so only wait for it. Marking
        // it would queue a second update once the turn ends.
        if updating == id {
            await turnEnded(id)
            return
        }
        // As the person's click: neither the ledger nor this run's memory holds the next turn back.
        // A turn that already reached its update takes this mark (``attempt``); one still reading
        // the machine (its `cannotUpdate` check) leaves it, and ``drainQueue()`` queues it again.
        retried.insert(id)
        if running == id {
            offered[id] = target
        } else {
            enqueue(target, urgent: true)
            // Due now, also an urgent entry waiting out a busy backoff (review of #29497).
            if let index = queue.firstIndex(where: { $0.target.id == id }), queue[index].due > elapsed() {
                queue[index].due = elapsed()
                sleeper?.cancel()
            }
        }
        await turnEnded(id)
        // The joined turn ended before its update ran: the mark queued its next turn, which runs
        // the update; wait for that one too.
        if retried.contains(id) { await turnEnded(id) }
    }

    /// Whether an ``updateNow`` waits on a turn of target `id` (tests order a join against it).
    func awaitsTurn(_ id: String) -> Bool { turnWaiters[id] != nil }

    /// Waits until a turn of target `id` ends, or the queue drops it, or the task is cancelled.
    private func turnEnded(_ id: String) async {
        guard running == id || queue.contains(where: { $0.target.id == id }) else { return }
        // One element at most: the stream only ever finishes.
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let key = UUID()
        turnWaiters[id, default: [:]][key] = continuation
        await withTaskCancellationHandler {
            for await _ in stream { break }
        } onCancel: {
            continuation.finish()
        }
        turnWaiters[id]?[key] = nil
        if turnWaiters[id]?.isEmpty == true { turnWaiters[id] = nil }
    }

    /// Ends the waits of ``updateNow(_:)`` on target `id` (nil: on every target).
    private func endTurnWaits(_ id: String?) {
        let ended = id.map { turnWaiters.removeValue(forKey: $0).map { Array($0.values) } ?? [] }
            ?? turnWaiters.values.flatMap(\.values)
        if id == nil { turnWaiters.removeAll() }
        for continuation in ended { continuation.finish() }
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
        guard dependencies.enabled() else { return }
        offered[target.id] = target
        guard running != target.id else { return }
        let now = elapsed()
        if let index = queue.firstIndex(where: { $0.target.id == target.id }) {
            queue[index].target = target
            // Offered again while it waits out an offline backoff: a source offers only connected
            // machines, so it is back. Its turn comes now.
            if queue[index].offline, queue[index].due > now {
                queue[index].due = now
                sleeper?.cancel()
            }
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
            endTurnWaits(nil)
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
                endTurnWaits(nil)
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
            endTurnWaits(pending.target.id)
            // The person clicked Update while this turn read the machine, before any update ran.
            if retried.contains(pending.target.id), let target = offered[pending.target.id] {
                enqueue(target, urgent: false)
            }
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
        // The person asked for this one (``retry(_:)``): what the ledger and this run remember of it
        // does not hold it back.
        let retry = retried.remove(target.id) != nil
        // Its line goes when it is dropped below: the person asked, or it said before that it could
        // not update and runs another build now (its "cannot update" line no longer holds).
        var clearLine = retry
        // Before the run's own memory (`settled`): a machine reinstalled since it said it cannot
        // update is asked again at its next offer, in this run too.
        if let known = ledger.cannotUpdate?[target.id] {
            // Each answer below replaces an offline line.
            offlineShown.remove(target.id)
            let now = await target.currentBuild()
            if now == nil, !(await target.urgent) {
                // Nothing to say now: it serves all this app uses (repaired), it is gone, or the
                // toggles are off. Its line goes; the ledger keeps the answer for that build.
                await deps.report(DaemonUpdateEvent(target, .cleared))
                return nil
            }
            guard retry || now != known.build else {
                // Still the build that could not update in place: its line again, no attempt.
                settled[target.id] = local.hash
                // Unless the person clicked Update meanwhile: the next turn answers that click,
                // and this one's report would end the click's "updating" line.
                if !retried.contains(target.id) {
                    await deps.report(DaemonUpdateEvent(target, .cannotUpdate(reason: known.reason), build: local.hash))
                }
                return nil
            }
            // It runs another build now (reinstalled), or the app refuses its daemon: ask it
            // again, on this build too.
            ledger.cannotUpdate?[target.id] = nil
            ledger.targets[target.id] = nil
            settled[target.id] = nil
            write(ledger)
            clearLine = true
        }
        if retry, ledger.attempted(target.id) || settled[target.id] != nil {
            ledger.targets[target.id] = nil
            settled[target.id] = nil
            write(ledger)
        }
        guard !ledger.attempted(target.id), settled[target.id] != local.hash else { return await dropped(pending, asked: clearLine) }
        // Read at its turn: the machine may have gone, or reached this build meanwhile.
        let urgent = await target.urgent
        let reported = await target.currentBuild()
        let current = DaemonBuildCommit(reported)
        if let current, local.sameCommit(current.hash) { return await dropped(pending, asked: clearLine) }
        if let current, current.dirty || current.isNewer(than: local) {
            Self.logger.info("\(target.displayName, privacy: .public) runs \(current.hash, privacy: .public)\(current.dirty ? " with local changes" : ", newer than this app's build", privacy: .public); left alone")
            return await dropped(pending, asked: clearLine)
        }
        guard current != nil || urgent else {
            // Still offline: its line stays until it connects and is offered again (remembered,
            // so an offer that then needs no update clears it).
            if pending.offline || offlineShown.contains(target.id), !clearLine {
                offlineShown.insert(target.id)
                return nil
            }
            return await dropped(pending, asked: clearLine)
        }
        // Busy for ``Dependencies/updateBusyAfter`` or longer (at once when it is zero): this update
        // does not wait for an idle moment.
        let asked = elapsed()
        let whileBusy = asked - (pending.firstBusy ?? asked) >= deps.updateBusyAfter
        offlineShown.remove(target.id)
        await deps.report(DaemonUpdateEvent(target, .updating))
        // A click until now is answered by this update.
        retried.remove(target.id)
        updating = target.id
        let outcome = await target.update(to: local, whileBusy: whileBusy)
        updating = nil
        Self.logger.info("\(Self.logLine(target.displayName, to: local.hash, whileBusy: whileBusy, outcome), privacy: .public)")
        if outcome == .busy || outcome == .unreachable {
            var again = pending
            let now = elapsed()
            let since = again.firstBusy ?? now
            again.firstBusy = since
            again.offline = outcome == .unreachable
            let delay = again.backoff.next()
            guard now + delay - since <= deps.giveUpAfter else {
                // Not settled: its next offer, once it connects, updates it in this run. Its line stays.
                if again.offline {
                    Self.logger.info("\(target.displayName, privacy: .public) stayed offline; updated when it connects")
                    offlineShown.insert(target.id)
                    await deps.report(DaemonUpdateEvent(target, .offline))
                    return nil
                }
                Self.logger.info("\(target.displayName, privacy: .public) stayed busy; left for the next launch")
                settled[target.id] = local.hash
                // Not "will try again": no retry comes in this run.
                await deps.report(DaemonUpdateEvent(target, .cleared))
                return nil
            }
            await deps.report(DaemonUpdateEvent(target, again.offline ? .offline : .retrying))
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
            // Kept across builds only with the build it ran: an unknown build (a refused daemon's)
            // cannot show later that the machine is still the same.
            if case .unsupported(let reason) = outcome, let reported, !reported.isEmpty {
                var known = ledger.cannotUpdate ?? [:]
                known[target.id] = DaemonUpdateLedger.CannotUpdate(build: reported, reason: reason)
                ledger.cannotUpdate = known
            }
            write(ledger)
        }
        await deps.report(Self.event(target, outcome, local: local))
        return nil
    }

    private func write(_ ledger: DaemonUpdateLedger) {
        do { try ledger.write(dependencies.directory) } catch {
            Self.logger.error("daemon update ledger not written: \(String(describing: error), privacy: .public)")
        }
    }

    /// Drops `pending`, which no longer needs an update; one asked again before leaves the board,
    /// since no retry comes.
    /// `asked`: the person's click (``retry(_:)``) asked for it, or it could not update before and
    /// runs another build now, so its line (a machine that could not update) goes too. An offline
    /// line kept after 6 hours (``offlineShown``) goes as well: it connected needing no update.
    private func dropped(_ pending: Pending, asked: Bool = false) async -> Pending? {
        let wasOffline = offlineShown.remove(pending.target.id) != nil
        if pending.firstBusy != nil || asked || wasOffline { await dependencies.report(DaemonUpdateEvent(pending.target, .cleared)) }
        return nil
    }

    /// The queue's log line for one update of `name` to `hash`: the outcome as Swift describes it,
    /// except a hold, which reads `held (<the daemon's words>)`.
    nonisolated static func logLine(_ name: String, to hash: String, whileBusy: Bool, _ outcome: DaemonUpdateOutcome) -> String {
        let said = if case .held(let reason) = outcome { "held (\(reason))" } else { String(describing: outcome) }
        return "\(name) to \(hash)\(whileBusy ? " while busy" : ""): \(said)"
    }

    /// What the ledger keeps for `outcome`: every final outcome. `busy`, `unreachable`, `needsBinary`,
    /// `handledElsewhere` and `held` are not final: the next launch asks again.
    nonisolated static func recorded(_ outcome: DaemonUpdateOutcome) -> String? {
        switch outcome {
        case .updated: "updated"
        case .current: "current"
        case .rolledBack: "rolledBack"
        case .unsupported: "unsupported"
        case .failed: "failed"
        case .busy, .unreachable, .needsBinary, .handledElsewhere, .held: nil
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
        case .unreachable: DaemonUpdateEvent(target, .offline)
        case .needsBinary(let triple): DaemonUpdateEvent(target, .failed(reason: "no build for \(triple)", rolledBack: false), build: build)
        case .rolledBack(let reason): DaemonUpdateEvent(target, .failed(reason: reason, rolledBack: true), notify: true, build: build)
        case .handledElsewhere, .held: DaemonUpdateEvent(target, .cleared)
        // Not a failure: no notice, the board's grouped line.
        case .unsupported(let reason): DaemonUpdateEvent(target, .cannotUpdate(reason: reason), build: build)
        case .failed(let reason): DaemonUpdateEvent(target, .failed(reason: reason, rolledBack: false), notify: true, build: build)
        }
    }
}
