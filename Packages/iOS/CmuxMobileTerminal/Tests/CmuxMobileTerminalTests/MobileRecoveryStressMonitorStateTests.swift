#if DEBUG
import Testing
@testable import CmuxMobileTerminal

@Suite("MobileRecoveryStressMonitorState")
struct MobileRecoveryStressMonitorStateTests {
    @Test("records cycle and drain completion")
    func recordsDrainCompletion() {
        var state = MobileRecoveryStressMonitorState(
            startMilliseconds: 0,
            heartbeatTimeoutMilliseconds: 2_000,
            freeDrainDeadlineMilliseconds: 10_000
        )
        state.beginCycle(3, generation: 12, pendingFreesBefore: 0, atMilliseconds: 100)
        state.recordRecoveryResult(pendingFreesAfter: 1)
        #expect(state.activeCycleDrained == false)
        state.recordFreeDrain(pendingFrees: 0, atMilliseconds: 250)
        #expect(state.activeCycleDrained)
        #expect(state.activeCycle?.cycle == 3)
        #expect(state.activeCycle?.generation == 12)
        #expect(state.activeCycle?.drainedMilliseconds == 250)
    }

    @Test("detects free drain deadline")
    func detectsFreeDrainDeadline() {
        var state = MobileRecoveryStressMonitorState(
            startMilliseconds: 0,
            heartbeatTimeoutMilliseconds: 2_000,
            freeDrainDeadlineMilliseconds: 10_000
        )
        state.recordHeartbeat(atMilliseconds: 9_000)
        state.beginCycle(4, generation: 20, pendingFreesBefore: 0, atMilliseconds: 0)
        state.recordRecoveryResult(pendingFreesAfter: 1)
        let stall = state.evaluate(atMilliseconds: 10_000)
        #expect(stall?.kind == .freeDrain)
        #expect(stall?.cycle == 4)
        #expect(stall?.generation == 20)
        #expect(stall?.pendingFrees == 1)
    }

    @Test("detects stale heartbeat")
    func detectsHeartbeatDeadline() {
        var state = MobileRecoveryStressMonitorState(
            startMilliseconds: 0,
            heartbeatTimeoutMilliseconds: 2_000,
            freeDrainDeadlineMilliseconds: 10_000
        )
        state.recordHeartbeat(atMilliseconds: 100)
        let stall = state.evaluate(atMilliseconds: 2_100)
        #expect(stall?.kind == .heartbeat)
        #expect(stall?.elapsedMilliseconds == 2_000)
    }

    @Test("heartbeat deadline wins before free drain deadline")
    func heartbeatWinsBeforeFreeDrain() {
        var state = MobileRecoveryStressMonitorState(
            startMilliseconds: 0,
            heartbeatTimeoutMilliseconds: 2_000,
            freeDrainDeadlineMilliseconds: 10_000
        )
        state.recordHeartbeat(atMilliseconds: 0)
        state.beginCycle(5, generation: 30, pendingFreesBefore: 0, atMilliseconds: 0)
        state.recordRecoveryResult(pendingFreesAfter: 1)
        let stall = state.evaluate(atMilliseconds: 2_000)
        #expect(stall?.kind == .heartbeat)
        #expect(stall?.cycle == 5)
        #expect(stall?.generation == 30)
    }
}
#endif
