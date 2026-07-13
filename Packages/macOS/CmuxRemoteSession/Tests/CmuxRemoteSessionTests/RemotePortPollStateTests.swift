import Testing
@testable import CmuxRemoteSession

@Suite("Remote fallback port poll state")
struct RemotePortPollStateTests {
    @Test("Incomplete host-wide scans retain old ports and apply positives")
    func incompleteHostWideScanMergesPositives() {
        var state = RemotePortPollState()

        state.apply(observedPorts: [4200], mode: .hostWide, completeness: .complete)
        state.apply(observedPorts: [5173], mode: .hostWide, completeness: .incomplete)

        #expect(state.publishedPorts == [4200, 5173])
        #expect(state.baselinePorts == nil)
    }

    @Test("Incomplete host-wide delta scans preserve state and merge positives")
    func incompleteHostWideDeltaScanMergesPositives() {
        var state = RemotePortPollState()
        state.apply(observedPorts: [3000], mode: .hostWideDelta, completeness: .complete)
        state.apply(observedPorts: [3000, 4200], mode: .hostWideDelta, completeness: .complete)

        let didApply = state.apply(
            observedPorts: [3000, 5173],
            mode: .hostWideDelta,
            completeness: .incomplete
        )

        #expect(didApply)
        #expect(state.baselinePorts == [3000])
        #expect(state.publishedPorts == [4200, 5173])
    }

    @Test("Complete delta scans establish a baseline and retain one transient miss")
    func completeHostWideDeltaScanReconcilesMisses() {
        var state = RemotePortPollState()

        state.apply(observedPorts: [3000], mode: .hostWideDelta, completeness: .complete)
        #expect(state.baselinePorts == [3000])
        #expect(state.publishedPorts.isEmpty)

        state.apply(observedPorts: [3000, 4200], mode: .hostWideDelta, completeness: .complete)
        #expect(state.publishedPorts == [4200])

        state.apply(observedPorts: [3000], mode: .hostWideDelta, completeness: .complete)
        #expect(state.publishedPorts == [4200])
    }

    @Test("Mode and lifecycle resets clear the intended state")
    func resetBehavior() {
        var state = RemotePortPollState()
        state.apply(observedPorts: [3000], mode: .hostWideDelta, completeness: .complete)
        state.apply(observedPorts: [3000, 4200], mode: .hostWideDelta, completeness: .complete)

        state.resetScanHistory()
        #expect(state.baselinePorts == nil)
        #expect(state.publishedPorts == [4200])

        state.reset()
        #expect(state.baselinePorts == nil)
        #expect(state.publishedPorts.isEmpty)
    }

    @Test("Incomplete TTY mode transitions preserve fallback state")
    func incompleteTTYTransitionPreservesState() {
        var state = RemotePortPollState()
        state.apply(observedPorts: [4200], mode: .hostWide, completeness: .complete)

        let didApplyIncomplete = state.apply(
            observedPorts: [],
            mode: .ttyScoped,
            completeness: .incomplete
        )
        #expect(didApplyIncomplete == false)
        #expect(state.publishedPorts == [4200])

        let didApplyComplete = state.apply(
            observedPorts: [],
            mode: .ttyScoped,
            completeness: .complete
        )
        #expect(didApplyComplete)
        #expect(state.publishedPorts.isEmpty)
    }
}
