#if DEBUG
import Foundation

/// Pure state machine for heartbeat and recovery-free drain deadlines.
struct MobileRecoveryStressMonitorState: Equatable, Sendable {
    let heartbeatTimeoutMilliseconds: Int64
    let freeDrainDeadlineMilliseconds: Int64
    private(set) var lastHeartbeatMilliseconds: Int64
    private(set) var activeCycle: MobileRecoveryStressCycleRecord?
    private(set) var stalled: MobileRecoveryStressStall?

    init(
        startMilliseconds: Int64 = 0,
        heartbeatTimeoutMilliseconds: Int64 = 2_000,
        freeDrainDeadlineMilliseconds: Int64 = 10_000
    ) {
        self.heartbeatTimeoutMilliseconds = heartbeatTimeoutMilliseconds
        self.freeDrainDeadlineMilliseconds = freeDrainDeadlineMilliseconds
        self.lastHeartbeatMilliseconds = startMilliseconds
    }

    mutating func recordHeartbeat(atMilliseconds now: Int64) {
        lastHeartbeatMilliseconds = now
    }

    mutating func beginCycle(
        _ cycle: Int,
        generation: UInt64,
        pendingFreesBefore: Int,
        atMilliseconds now: Int64
    ) {
        activeCycle = MobileRecoveryStressCycleRecord(
            cycle: cycle,
            generation: generation,
            pendingFreesBefore: pendingFreesBefore,
            startedMilliseconds: now,
            pendingFreesAfter: nil,
            freeDrained: false,
            drainedMilliseconds: nil
        )
    }

    mutating func recordRecoveryResult(pendingFreesAfter: Int) {
        activeCycle?.pendingFreesAfter = pendingFreesAfter
        if pendingFreesAfter == 0 {
            activeCycle?.freeDrained = true
        }
    }

    mutating func recordFreeDrain(pendingFrees: Int, atMilliseconds now: Int64) {
        guard activeCycle != nil else { return }
        activeCycle?.pendingFreesAfter = pendingFrees
        if pendingFrees == 0 {
            activeCycle?.freeDrained = true
            activeCycle?.drainedMilliseconds = now
        }
    }

    var activeCycleDrained: Bool {
        activeCycle?.freeDrained == true
    }

    mutating func evaluate(atMilliseconds now: Int64) -> MobileRecoveryStressStall? {
        if let stalled {
            return stalled
        }

        let heartbeatElapsed = max(0, now - lastHeartbeatMilliseconds)
        if heartbeatElapsed >= heartbeatTimeoutMilliseconds {
            let stall = MobileRecoveryStressStall(
                kind: .heartbeat,
                cycle: activeCycle?.cycle,
                generation: activeCycle?.generation,
                pendingFrees: activeCycle?.pendingFreesAfter ?? activeCycle?.pendingFreesBefore ?? 0,
                elapsedMilliseconds: heartbeatElapsed
            )
            stalled = stall
            return stall
        }

        guard let cycle = activeCycle,
              cycle.freeDrained == false,
              let pendingFreesAfter = cycle.pendingFreesAfter,
              pendingFreesAfter > 0 else {
            return nil
        }
        let freeElapsed = max(0, now - cycle.startedMilliseconds)
        if freeElapsed >= freeDrainDeadlineMilliseconds {
            let stall = MobileRecoveryStressStall(
                kind: .freeDrain,
                cycle: cycle.cycle,
                generation: cycle.generation,
                pendingFrees: pendingFreesAfter,
                elapsedMilliseconds: freeElapsed
            )
            stalled = stall
            return stall
        }
        return nil
    }
}
#endif
