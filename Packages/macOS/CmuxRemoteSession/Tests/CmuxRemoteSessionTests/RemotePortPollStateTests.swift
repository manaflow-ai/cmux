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

    @Test("Incomplete host-wide delta scans preserve baseline and publication")
    func incompleteHostWideDeltaScanPreservesState() {
        var state = RemotePortPollState()
        state.apply(observedPorts: [3000], mode: .hostWideDelta, completeness: .complete)
        state.apply(observedPorts: [3000, 4200], mode: .hostWideDelta, completeness: .complete)

        let didApply = state.apply(
            observedPorts: [3000, 5173],
            mode: .hostWideDelta,
            completeness: .incomplete
        )

        #expect(didApply == false)
        #expect(state.baselinePorts == [3000])
        #expect(state.publishedPorts == [4200])
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
}
