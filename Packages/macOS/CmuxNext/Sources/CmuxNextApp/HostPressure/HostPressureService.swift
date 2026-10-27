import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHostPressure
import CmuxNextWakeups
import AppKit
import Observation
import os

/// The host's pressure for every window (cmuxterm-hq#2995; Leo: "warn a bit
/// earlier", "just warn for now"): one `HostPressureMonitor` for the app, on
/// acpmux's host budget, and the level the windows' top-row indicator shows.
///
/// Stop condition: it runs while a window's indicator subscribes
/// (`subscribe()`: the feature `hostPressure` is on and that window can be seen), and
/// stops when the last one unsubscribes (every window hidden, minimized, occluded or closed) and at quit (`stop()`). Cleanup: the monitor ends its
/// subscription to the app's memory pressure feed, cancels its timer and any read in flight, and drops
/// a level change still queued.
///
/// Scheduling (p06-scheduler.md, task p06-scheduler-317: "HostPressure is background"): the monitor's start and stop
/// hops run off the main thread at best effort, each after the one before; a level change comes back as one posted
/// background task, the forced level is a background ``ServiceObservation`` and quit an ``AppEvents`` subscription.
/// Only the indicator's own glyph apply (`HostPressureIndicatorView`'s level observation) runs as visible, as any
/// view's model update does. Chromium posts the reply of thread-pool work as a typed UI-thread task
/// (`base::ThreadPool::PostTaskAndReplyWithResult`, content/browser/scheduler/browser_task_queues.h).
@MainActor @Observable
final class HostPressureService {
    /// The app's one service, made by the first window's indicator.
    private static var current: HostPressureService?

    static func shared(acpmux: @autoclosure () -> AcpmuxEnvironment?,
                       memoryPressure: @autoclosure () -> HostPressureMonitor.MemoryPressureSubscription,
                       mainWork: MainWorkScheduler, work: BackgroundWork, appEvents: AppEvents) -> HostPressureService {
        if let current { return current }
        let service = HostPressureService(acpmux: acpmux(), memoryPressure: memoryPressure(), mainWork: mainWork, work: work,
                                          appEvents: appEvents)
        current = service
        return service
    }

    /// The level the windows show: Debug Settings' forced level, else the monitor's.
    var level: HostPressureLevel { forced?.level ?? monitored }
    /// The numbers behind it (the popover's), nil until the first read.
    var verdict: HostBudgetVerdict? { forced.flatMap { $0.level.map(Self.sample) } ?? monitoredVerdict }

    /// Counts the times the shown level entered critical (a forced level included). A window that
    /// closed its banner keeps it closed while this stays the same: until the level falls below
    /// critical, the monitor stops (its level resets to normal) or a force changes the shown level.
    private(set) var criticalSpell = 0
    @ObservationIgnored private var lastLevel = HostPressureLevel.normal
    private var monitored = HostPressureLevel.normal
    private var monitoredVerdict: HostBudgetVerdict?
    private var forced: HostPressureForce?
    /// The app's main-thread scheduler: level changes, the forced level and the indicators' releases post here.
    @ObservationIgnored let mainWork: MainWorkScheduler
    @ObservationIgnored private let work: BackgroundWork
    @ObservationIgnored private let monitor: HostPressureMonitor
    @ObservationIgnored private let acpmux: AcpmuxEnvironment?
    @ObservationIgnored private var forceObservation: ServiceObservation<HostPressureForce>?
    @ObservationIgnored private var subscribers = 0
    @ObservationIgnored private var running = false
    @ObservationIgnored private var quitObservation: EventSubscription?
    /// The last start or stop hop: each waits for the one before, so a window closing and
    /// another opening reach the monitor in order.
    @ObservationIgnored private var lifecycle: Task<Void, any Error>?
    /// Bumped by each start and stop.
    @ObservationIgnored private var lifecycleGeneration = 0
    /// The generation the monitor should run for, read by the monitor actor itself right before it
    /// builds its timer, so a stop issued while a start hop is in flight wins.
    @ObservationIgnored nonisolated private let wanted = Mutex(0)
    private static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "host-pressure")

    /// - Parameters:
    ///   - acpmux: The daemon whose verdict counts, nil without one (showcase, mock agent host).
    ///   - memoryPressure: The app's one memory pressure feed (`MemoryPressureEvents.hostPressureSubscription`).
    ///   - store: The Debug Settings tunables (the forced level).
    ///   - mainWork: The app's main-thread scheduler.
    ///   - work: The app's off-main work (the monitor's start and stop hops, a session's stop).
    ///   - appEvents: The app's notices (quit).
    init(acpmux: AcpmuxEnvironment?, memoryPressure: @escaping HostPressureMonitor.MemoryPressureSubscription,
         store: TunableStore = .shared, mainWork: MainWorkScheduler, work: BackgroundWork, appEvents: AppEvents) {
        self.acpmux = acpmux
        self.mainWork = mainWork
        self.work = work
        var reader: (@Sendable () async -> HostBudgetVerdict?)?
        if let acpmux {
            reader = { @Sendable () async -> HostBudgetVerdict? in
                guard let data = await acpmux.hostPressure() else { return nil }
                return try? JSONDecoder().blockingDecode(HostBudgetVerdict.self, from: data)
            }
        }
        // A level change reaches main as one background task; the indicators' glyphs follow it in their own flush.
        monitor = HostPressureMonitor(source: LocalHostPressureSource(acpmux: reader), memoryPressure: memoryPressure,
                                      deliver: { change in mainWork.postFromAnyThread(.background, owner: "HostPressureService.level") { change() } })
        // A service observation: the forced level is model state every window reads, and it applies while they hide.
        forceObservation = ServiceObservation(.background, owner: "HostPressureService.force", on: mainWork) {
            HostPressureTunables.force.value(in: store)
        } apply: { [weak self] force in
            guard let self else { return }
            forced = force == .off ? nil : force
            noteLevel()
        }
        quitObservation = appEvents.subscribe(NSApplication.willTerminateNotification, owner: "HostPressureService.quit") { [weak self] in
            self?.stop()
        }
    }

    /// How many windows' indicators are subscribed, and whether the monitor (and its timer) runs.
    var subscriberCount: Int { subscribers }
    var isMonitoring: Bool { running }
    /// Whether Debug Settings forces the level (its sessions are samples, with no Stop).
    var isForced: Bool { forced != nil }
    /// Whether the monitor itself runs (its timer and pressure subscription exist), after the hops so far.
    func monitorIsRunning() async -> Bool {
        _ = try? await lifecycle?.value
        return await monitor.isRunning
    }

    /// A window's indicator joined: the monitor runs while one is subscribed.
    func subscribe() {
        subscribers += 1
        updateRunning()
    }

    /// A window's indicator left its window.
    func unsubscribe() {
        subscribers = max(0, subscribers - 1)
        updateRunning()
    }

    private func updateRunning() {
        if subscribers > 0, !running {
            running = true
            lifecycleGeneration += 1
            let (monitor, previous, generation) = (monitor, lifecycle, lifecycleGeneration)
            wanted.withLock { $0 = generation }
            let onChange: HostPressureMonitor.Change = { [weak self] level, verdict in
                self?.monitored = level
                self?.monitoredVerdict = verdict
                self?.noteLevel()
            }
            // One hop off main to start the monitor, after the previous hop; the monitor actor checks `wanted` before it
            // starts anything, so a stop issued meanwhile wins and this start does nothing.
            // priority-allow: only tests await lifecycle (monitorIsRunning); no person waits for the Debug sampler's start
            lifecycle = work.task(.bestEffort) { [self] in
                _ = try? await previous?.value
                await monitor.start(while: { self.isWanted(generation) }, onChange: onChange)
            }
        } else if subscribers == 0, running {
            stopMonitor()
        }
    }

    /// Whether run `generation` is still the one the windows want (the monitor actor asks before it starts).
    nonisolated private func isWanted(_ generation: Int) -> Bool {
        wanted.withLock { $0 } == generation
    }

    /// At quit: stops the monitor, the Debug Settings observation and the quit observer.
    func stop() {
        forceObservation?.cancel()
        forceObservation = nil
        quitObservation?.cancel()
        quitObservation = nil
        subscribers = 0
        if running { stopMonitor() }
    }

    private func stopMonitor() {
        running = false
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        wanted.withLock { $0 = generation }
        monitored = .normal
        monitoredVerdict = nil
        noteLevel()
        let (monitor, previous) = (monitor, lifecycle)
        // One hop off main to stop the monitor, after the previous hop; it ends when its subscription and timer are cancelled.
        // priority-allow: only tests await lifecycle (monitorIsRunning); no person waits for the Debug sampler's stop
        lifecycle = work.task(.bestEffort) {
            _ = try? await previous?.value
            await monitor.stop()
        }
    }

    /// Starts a new critical spell when the shown level enters critical.
    private func noteLevel() {
        if level == .critical, lastLevel != .critical { criticalSpell += 1 }
        lastLevel = level
    }

    /// Stops one acpmux session's agent (resumable): the person's Stop asks acpmux off the main thread, and once it
    /// answers the popover drops the session in one userBlocking task. A forced level's sessions are samples, so their
    /// Stop asks acpmux nothing.
    func stopSession(_ session: HostBudgetSession) {
        guard forced == nil, let acpmux else { return }
        let (id, name, log, mainWork) = (session.sessionId, session.name, Self.log, mainWork)
        let stopped: @MainActor @Sendable () -> Void = { [weak self] in self?.dropSession(id) }
        work.task(.userBlocking) {
            do {
                try await acpmux.stopSession(id: id)
            } catch {
                log.error("stopping \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                return
            }
            mainWork.postFromAnyThread(.userBlocking, owner: "HostPressureService.sessionStopped") { stopped() }
        }
    }

    /// The monitor's numbers without the stopped session `id`.
    private func dropSession(_ id: String) {
        guard var verdict = monitoredVerdict else { return }
        verdict.top?.removeAll { $0.sessionId == id }
        monitoredVerdict = verdict
    }

    /// The forced level's numbers: the cosmic-gray incident (cmuxterm-hq#2995) at critical, a
    /// busy-but-fine 12-core Mac at warning.
    static func sample(_ level: HostPressureLevel) -> HostBudgetVerdict {
        let critical = level == .critical
        var verdict = HostBudgetVerdict(host: "cosmic-gray", cores: 12, load1: critical ? 146 : 9.6,
                                        pressure: critical ? .warn : .normal, availableRAMFraction: critical ? 0.04 : 0.31,
                                        swapMBPerMin: critical ? 410 : 0)
        verdict.localTurns = critical ? 39 : 14
        verdict.backgroundProcesses = critical ? 1298 : 212
        let top = critical
            ? #"[{"session_id":"s1","name":"app-efficiency","turns":9,"processes":410},{"session_id":"s2","name":"chief-fix","turns":7,"processes":302},{"session_id":"s3","name":"gui-push","turns":5,"processes":188}]"#
            : #"[{"session_id":"s1","name":"app-efficiency","turns":4,"processes":80},{"session_id":"s2","name":"chief-fix","turns":3,"processes":61}]"#
        verdict.top = try? JSONDecoder().blockingDecode([HostBudgetSession].self, from: Data(top.utf8))
        return verdict
    }
}
