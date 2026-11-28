#if DEBUG
import Foundation

/// Background-readable monitor for main-thread heartbeat and free-drain progress.
actor MobileRecoveryStressMonitor {
    private let start: ContinuousClock.Instant
    private let reporter: MobileRecoveryStressReporter
    private var state: MobileRecoveryStressMonitorState
    private var stallEmitted = false

    init(
        start: ContinuousClock.Instant,
        reporter: MobileRecoveryStressReporter = MobileRecoveryStressReporter(),
        state: MobileRecoveryStressMonitorState = MobileRecoveryStressMonitorState()
    ) {
        self.start = start
        self.reporter = reporter
        self.state = state
    }

    func recordHeartbeat(now: ContinuousClock.Instant) {
        state.recordHeartbeat(atMilliseconds: milliseconds(at: now))
    }

    func beginCycle(
        _ cycle: Int,
        generation: UInt64,
        pendingFreesBefore: Int,
        now: ContinuousClock.Instant
    ) {
        state.beginCycle(
            cycle,
            generation: generation,
            pendingFreesBefore: pendingFreesBefore,
            atMilliseconds: milliseconds(at: now)
        )
    }

    func recordRecoveryResult(pendingFreesAfter: Int) {
        state.recordRecoveryResult(pendingFreesAfter: pendingFreesAfter)
    }

    func recordFreeDrain(pendingFrees: Int, now: ContinuousClock.Instant) {
        state.recordFreeDrain(pendingFrees: pendingFrees, atMilliseconds: milliseconds(at: now))
    }

    func activeCycleDrained() -> Bool {
        state.activeCycleDrained
    }

    func activeCycleRecord() -> MobileRecoveryStressCycleRecord? {
        state.activeCycle
    }

    func stalled() -> Bool {
        state.stalled != nil
    }

    @discardableResult
    func emitStallIfNeeded(now: ContinuousClock.Instant) -> Bool {
        guard let stall = state.evaluate(atMilliseconds: milliseconds(at: now)) else {
            return false
        }
        if !stallEmitted {
            stallEmitted = true
            reporter.emit(stall.marker)
        }
        return true
    }

    private func milliseconds(at instant: ContinuousClock.Instant) -> Int64 {
        let duration = start.duration(to: instant)
        let components = duration.components
        let seconds = components.seconds * 1_000
        let attoseconds = components.attoseconds / 1_000_000_000_000_000
        return seconds + Int64(attoseconds)
    }
}
#endif
