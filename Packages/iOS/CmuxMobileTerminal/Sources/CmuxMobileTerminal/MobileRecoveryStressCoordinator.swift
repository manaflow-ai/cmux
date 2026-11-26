#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import CmuxMobileTerminalKit
import Foundation
import UIKit

@MainActor
final class MobileRecoveryStressCoordinator: NSObject, GhosttySurfaceViewDelegate {
    weak var surfaceView: GhosttySurfaceView?
    private let configuration: MobileRecoveryStressConfiguration
    private let clock: ContinuousClock
    private let monitor: MobileRecoveryStressMonitor
    private let reporter: MobileRecoveryStressReporter
    private var scenarioTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    init(
        configuration: MobileRecoveryStressConfiguration,
        clock: ContinuousClock = ContinuousClock(),
        reporter: MobileRecoveryStressReporter = MobileRecoveryStressReporter()
    ) {
        self.configuration = configuration
        self.clock = clock
        self.reporter = reporter
        self.monitor = MobileRecoveryStressMonitor(start: clock.now, reporter: reporter)
        super.init()
    }

    deinit {
        scenarioTask?.cancel()
        heartbeatTask?.cancel()
        watchdogTask?.cancel()
    }

    func start() {
        guard scenarioTask == nil else { return }
        if let surfaceView {
            GhosttySurfaceView.RecoveryStressObservers.set({ [weak self] snapshot in
                guard let self else { return }
                let monitor = self.monitor
                let clock = self.clock
                Task {
                    await monitor.recordFreeDrain(
                        pendingFrees: snapshot.pendingSurfaceFreeCount,
                        now: clock.now
                    )
                }
            }, for: surfaceView)
        }
        heartbeatTask = Task { @MainActor [weak self] in
            await self?.runHeartbeat()
        }
        watchdogTask = Task.detached(priority: .background) { [monitor, clock] in
            await MobileRecoveryStressCoordinator.runWatchdog(monitor: monitor, clock: clock)
        }
        scenarioTask = Task { @MainActor [weak self] in
            await self?.runScenario()
        }
    }

    func stop() {
        if let surfaceView { GhosttySurfaceView.RecoveryStressObservers.set(nil, for: surfaceView) }
        scenarioTask?.cancel()
        heartbeatTask?.cancel()
        watchdogTask?.cancel()
        scenarioTask = nil
        heartbeatTask = nil
        watchdogTask = nil
    }

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {}

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize, reportID: UInt64) {
        guard size.columns > 0, size.rows > 0 else { return }
        surfaceView.applyViewSize(cols: max(1, size.columns - 1), rows: max(1, size.rows - 1))
    }

    private func runHeartbeat() async {
        while !Task.isCancelled {
            await monitor.recordHeartbeat(now: clock.now)
            do {
                // Bounded DEBUG liveness cadence; cancellation is tied to harness teardown.
                try await clock.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
    }

    nonisolated private static func runWatchdog(
        monitor: MobileRecoveryStressMonitor,
        clock: ContinuousClock
    ) async {
        while !Task.isCancelled {
            do {
                // Bounded DEBUG watchdog cadence; cancellation is tied to harness teardown.
                try await clock.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            if await monitor.emitStallIfNeeded(now: clock.now) {
                return
            }
        }
    }

    private func runScenario() async {
        reporter.emit("recovery.stress.START cycles=\(configuration.cycles)")
        guard let view = surfaceView else { return }
        guard await waitForMountedSurface(view) else {
            reporter.emit("recovery.stress.DEADLOCK kind=mount elapsedMs=5000 pendingFrees=0")
            return
        }

        for cycle in 1...configuration.cycles {
            if Task.isCancelled {
                return
            }
            if await monitor.stalled() {
                return
            }

            let before = view.recoveryStressSnapshot()
            await monitor.beginCycle(
                cycle,
                generation: before.generation,
                pendingFreesBefore: before.pendingSurfaceFreeCount,
                now: clock.now
            )

            view.processOutput(Self.syntheticOutput(cycle: cycle))
            driveViewportChurn(on: view, cycle: cycle)

            let after = view.forceRecoveryForStress()
            await monitor.recordRecoveryResult(pendingFreesAfter: after.pendingSurfaceFreeCount)
            driveViewportChurn(on: view, cycle: cycle + configuration.cycles)
            reporter.emit(
                "recovery.stress.cycle cycle=\(cycle) generation=\(before.generation) pendingBefore=\(before.pendingSurfaceFreeCount) pendingAfter=\(after.pendingSurfaceFreeCount)"
            )

            guard await waitForActiveCycleToDrain(cycle: cycle) else {
                return
            }
        }

        reporter.emit("recovery.stress.PASS cycles=\(configuration.cycles)")
    }

    private func waitForMountedSurface(_ view: GhosttySurfaceView) async -> Bool {
        let deadline = clock.now + .seconds(5)
        while clock.now < deadline {
            if Task.isCancelled { return false }
            if view.window != nil && view.bounds.width > 100 && view.bounds.height > 100 && view.surface != nil {
                return true
            }
            do {
                // Bounded mount deadline; cancellation is tied to harness teardown.
                try await clock.sleep(for: .milliseconds(20))
            } catch {
                return false
            }
        }
        return view.window != nil && view.bounds.width > 100 && view.bounds.height > 100 && view.surface != nil
    }

    private func waitForActiveCycleToDrain(cycle: Int) async -> Bool {
        while !Task.isCancelled {
            if await monitor.activeCycleDrained() {
                if let record = await monitor.activeCycleRecord() {
                    reporter.emit(
                        "recovery.stress.drain cycle=\(cycle) generation=\(record.generation) drained=\(record.freeDrained) pendingAfter=\(record.pendingFreesAfter ?? -1)"
                    )
                }
                return true
            }
            if await monitor.emitStallIfNeeded(now: clock.now) {
                return false
            }
            do {
                // Bounded free-drain deadline; cancellation is tied to harness teardown.
                try await clock.sleep(for: .milliseconds(20))
            } catch {
                return false
            }
        }
        return false
    }

    private func driveViewportChurn(on view: GhosttySurfaceView, cycle: Int) {
        let width = CGFloat(360 + (cycle % 6) * 9)
        let height = CGFloat(620 + (cycle % 5) * 13)
        view.bounds = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        view.setNeedsLayout()
        view.layoutIfNeeded()

        let grid = view.currentGridSize
        let cols = max(20, grid.columns - ((cycle % 4) + 1))
        let rows = max(8, grid.rows - ((cycle % 3) + 1))
        view.applyViewSize(cols: cols, rows: rows)
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private static func syntheticOutput(cycle: Int) -> Data {
        var text = "\u{1b}[?2004h\u{1b}]133;A\u{07}\u{1b}]0;recovery stress \(cycle)\u{07}"
        for line in 0..<96 {
            text += "\u{1b}[38;5;\((line + cycle) % 216)m"
            text += "recovery-stress cycle=\(cycle) line=\(line) "
            text += "abcdefghijklmnopqrstuvwxyz 0123456789 wrapping payload "
            text += "\u{1b}[0m\r\n"
            if line % 8 == 0 {
                text += "\u{1b}]7;file://stress/recovery/\(cycle)/\(line)\u{07}"
                text += "\u{1b}[2K\r"
            }
        }
        text += "\u{1b}]133;B\u{07}\u{1b}[?2004l\r\n"
        return Data(text.utf8)
    }
}
#endif
