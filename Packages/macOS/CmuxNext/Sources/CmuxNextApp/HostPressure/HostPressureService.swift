import CmuxNextAgentPane
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
/// (`subscribe()`), and stops when the last one unsubscribes (its window
/// closed) and at quit (`stop()`). Cleanup: the monitor cancels its memory
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
    private static let log = Logger(subsystem: "com.cmuxterm.next", category: "host-pressure")

    /// `acpmux`: the daemon whose verdict counts, nil without one (showcase, mock agent host).
    init(acpmux: AcpmuxEnvironment?, store: TunableStore = .shared) {
        self.acpmux = acpmux
        let reader: (@Sendable () async -> HostBudgetVerdict?)? = acpmux.map { acpmux in
            { await acpmux.hostPressure().flatMap { try? JSONDecoder().decode(HostBudgetVerdict.self, from: $0) } }
        }
        monitor = HostPressureMonitor(source: LocalHostPressureSource(acpmux: reader))
        // task-owner: the service (cancelled in stop()); event-driven (Observation of the tunable store)
        forceObservation = Task { [weak self] in
            for await force in ObservationStream({ HostPressureTunables.force.value(in: store) }) {
                self?.forced = force == .off ? nil : force
            }
        }
        // task-owner: the service (cancelled in stop()); event-driven (the app's quit notification)
        quitObservation = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.willTerminateNotification) {
                self?.stop()
            }
        }
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
            let (monitor, previous) = (monitor, lifecycle)
            // task-owner: one hop to start the monitor, after the previous hop; it ends when the monitor has started
            lifecycle = Task {
                await previous?.value
                await monitor.start { [weak self] level, verdict in
                    self?.monitored = level
                    self?.monitoredVerdict = verdict
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
        monitored = .normal
        monitoredVerdict = nil
        let (monitor, previous) = (monitor, lifecycle)
        // task-owner: one hop to stop the monitor, after the previous hop; it ends when its source and timer are cancelled
        lifecycle = Task {
            await previous?.value
            await monitor.stop()
        }
    }

    /// Stops one acpmux session's agent (resumable); false when acpmux refused or did not answer.
    func stopSession(_ session: HostBudgetSession) async -> Bool {
        guard let acpmux else { return false }
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
