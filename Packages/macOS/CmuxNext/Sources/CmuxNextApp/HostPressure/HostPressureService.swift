import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHostPressure
import AppKit
import Observation
import os

/// The host's pressure for every window (cmuxterm-hq#2995; Leo: "warn a bit
/// earlier", "just warn for now"): one `HostPressureMonitor` for the app, on
/// acpmux's host budget, and the level the windows' top-row indicator shows.
///
/// Stop condition: it runs while a window's indicator subscribes
/// (`subscribe()`: the Debug toggle `hostPressure.enabled` is on and that window
/// can be seen), and stops when the last one unsubscribes (toggle off, or every
/// window hidden, minimized, occluded or closed) and at quit (`stop()`). Cleanup: the monitor cancels its memory
/// pressure source, its timer and any read in flight, and drops a level change
/// still queued.
@MainActor @Observable
final class HostPressureService {
    /// The app's one service, made by the first window's indicator.
    private static var current: HostPressureService?

    static func shared(acpmux: @autoclosure () -> AcpmuxEnvironment?) -> HostPressureService {
        if let current { return current }
        let service = HostPressureService(acpmux: acpmux())
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
    @ObservationIgnored private let monitor: HostPressureMonitor
    @ObservationIgnored private let acpmux: AcpmuxEnvironment?
    @ObservationIgnored private var forceObservation: Task<Void, Never>?
    @ObservationIgnored private var subscribers = 0
    @ObservationIgnored private var running = false
    @ObservationIgnored private var quitObservation: Task<Void, Never>?
    /// The last start or stop hop: each waits for the one before, so a window closing and
    /// another opening reach the monitor in order.
    @ObservationIgnored private var lifecycle: Task<Void, Never>?
    /// Bumped by each start and stop: a start hop whose number is no longer current when its turn
    /// comes (the last window left first) starts nothing.
    @ObservationIgnored private var lifecycleGeneration = 0
    /// The generation the monitor should run for, read by the monitor actor itself right before it
    /// builds its timer, so a stop issued while a start hop is in flight wins.
    @ObservationIgnored private let wanted = OSAllocatedUnfairLock(initialState: 0)
    private static let log = Logger(subsystem: "com.cmuxterm.next", category: "host-pressure")

    /// `acpmux`: the daemon whose verdict counts, nil without one (showcase, mock agent host).
    init(acpmux: AcpmuxEnvironment?, store: TunableStore = .shared) {
        self.acpmux = acpmux
        var reader: (@Sendable () async -> HostBudgetVerdict?)?
        if let acpmux {
            reader = { @Sendable () async -> HostBudgetVerdict? in
                guard let data = await acpmux.hostPressure() else { return nil }
                return try? JSONDecoder().decode(HostBudgetVerdict.self, from: data)
            }
        }
        monitor = HostPressureMonitor(source: LocalHostPressureSource(acpmux: reader))
        // task-owner: the service (cancelled in stop()); event-driven (Observation of the tunable store)
        forceObservation = Task { [weak self] in
            for await force in ObservationStream({ HostPressureTunables.force.value(in: store) }) {
                guard let self else { return }
                forced = force == .off ? nil : force
                noteLevel()
            }
        }
        // task-owner: the service (cancelled in stop()); event-driven (the app's quit notification)
        quitObservation = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.willTerminateNotification) {
                self?.stop()
            }
        }
    }

    /// How many windows' indicators are subscribed, and whether the monitor (and its timer) runs.
    var subscriberCount: Int { subscribers }
    var isMonitoring: Bool { running }
    /// Whether Debug Settings forces the level (its sessions are samples, with no Stop).
    var isForced: Bool { forced != nil }
    /// Whether the monitor itself runs (its timer and source exist), after the hops so far.
    func monitorIsRunning() async -> Bool {
        await lifecycle?.value
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
            let (monitor, previous, generation, wanted) = (monitor, lifecycle, lifecycleGeneration, wanted)
            wanted.withLock { $0 = generation }
            // task-owner: one hop to start the monitor, after the previous hop; it ends when the monitor has started
            lifecycle = Task { [weak self] in
                await previous?.value
                guard let self, lifecycleGeneration == generation else { return }
                await monitor.start(while: { wanted.withLock { $0 } == generation }) { [weak self] level, verdict in
                    self?.monitored = level
                    self?.monitoredVerdict = verdict
                    self?.noteLevel()
                }
            }
        } else if subscribers == 0, running {
            stopMonitor()
        }
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
        // task-owner: one hop to stop the monitor, after the previous hop; it ends when its source and timer are cancelled
        lifecycle = Task {
            await previous?.value
            await monitor.stop()
        }
    }

    /// Starts a new critical spell when the shown level enters critical.
    private func noteLevel() {
        if level == .critical, lastLevel != .critical { criticalSpell += 1 }
        lastLevel = level
    }

    /// Stops one acpmux session's agent (resumable); false when acpmux refused or did not answer.
    /// A forced level's sessions are samples, so their Stop asks acpmux nothing.
    func stopSession(_ session: HostBudgetSession) async -> Bool {
        guard forced == nil, let acpmux else { return false }
        do {
            try await acpmux.stopSession(id: session.sessionId)
            if var verdict = monitoredVerdict {
                verdict.top?.removeAll { $0.sessionId == session.sessionId }
                monitoredVerdict = verdict
            }
            return true
        } catch {
            Self.log.error("stopping \(session.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return false
        }
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
        verdict.top = try? JSONDecoder().decode([HostBudgetSession].self, from: Data(top.utf8))
        return verdict
    }
}
