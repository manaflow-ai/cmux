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

    @Test("TTY handoff retains fallback until bounded complete evidence expires it")
    func ttyTransitionRetentionIsBounded() {
        var state = RemotePortPollState()
        state.apply(observedPorts: [4200], mode: .hostWide, completeness: .complete)
        let didBegin = state.beginTTYTransition()
        #expect(didBegin)

        let incompleteFinished = state.advanceTTYTransition(completeness: .incomplete)
        #expect(incompleteFinished == false)
        #expect(state.publishedPorts == [4200])

        let firstCompleteFinished = state.advanceTTYTransition(completeness: .complete)
        #expect(firstCompleteFinished == false)
        #expect(state.publishedPorts == [4200])
        let secondCompleteFinished = state.advanceTTYTransition(completeness: .complete)
        #expect(secondCompleteFinished == false)
        #expect(state.publishedPorts == [4200])

        let thirdCompleteFinished = state.advanceTTYTransition(completeness: .complete)
        #expect(thirdCompleteFinished)
        #expect(state.publishedPorts.isEmpty)
    }

    @Test("Incomplete TTY handoff attempts expire after the explicit retention bound")
    func incompleteTTYTransitionAttemptsAreBounded() {
        var state = RemotePortPollState()
        state.apply(observedPorts: [4200], mode: .hostWide, completeness: .complete)
        _ = state.beginTTYTransition()

        let firstFinished = state.advanceTTYTransition(completeness: .incomplete)
        #expect(firstFinished == false)
        #expect(state.publishedPorts == [4200])
        let secondFinished = state.advanceTTYTransition(completeness: .incomplete)
        #expect(secondFinished == false)
        #expect(state.publishedPorts == [4200])

        let thirdFinished = state.advanceTTYTransition(completeness: .incomplete)
        #expect(thirdFinished)
        #expect(state.publishedPorts.isEmpty)
    }

    @Test("New host-wide evidence resets prior TTY handoff history")
    func hostWideEvidenceResetsTransitionHistory() {
        var state = RemotePortPollState()
        state.apply(observedPorts: [4200], mode: .hostWide, completeness: .complete)
        _ = state.beginTTYTransition()
        _ = state.advanceTTYTransition(completeness: .complete)
        _ = state.advanceTTYTransition(completeness: .complete)

        state.apply(observedPorts: [4200, 5173], mode: .hostWide, completeness: .complete)
        _ = state.beginTTYTransition()
        let didFinish = state.advanceTTYTransition(completeness: .complete)
        #expect(didFinish == false)
        #expect(state.publishedPorts == [4200, 5173])

        state.resetScanHistory()
        let didFinishAfterReset = state.advanceTTYTransition(completeness: .complete)
        #expect(didFinishAfterReset == false)
        #expect(state.publishedPorts == [4200, 5173])

        state.reset()
        #expect(state.publishedPorts.isEmpty)
    }
}
