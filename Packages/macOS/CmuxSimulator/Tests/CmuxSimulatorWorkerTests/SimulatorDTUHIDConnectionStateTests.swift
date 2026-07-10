import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator DTUHID connection state")
struct SimulatorDTUHIDConnectionStateTests {
    @Test("An XPC error permanently rejects subsequent sends")
    func invalidationIsTerminal() {
        let state = SimulatorDTUHIDConnectionState()
        #expect(state.isAvailable)

        state.markUnavailable()

        #expect(!state.isAvailable)
        state.markUnavailable()
        #expect(!state.isAvailable)
    }

    @Test("Local transmission barrier wait is cancellable and resumes once")
    func barrierCancellation() async {
        let waiter = SimulatorDTUHIDBarrierWaiter()
        let task = Task {
            await waiter.wait { _ in }
        }
        await Task.yield()
        task.cancel()
        #expect(await task.value == false)
        waiter.complete(true)
    }

    @Test("Local transmission barrier reports its callback result")
    func barrierCompletion() async {
        let waiter = SimulatorDTUHIDBarrierWaiter()
        #expect(await waiter.wait { completion in completion(true) })
    }
}
