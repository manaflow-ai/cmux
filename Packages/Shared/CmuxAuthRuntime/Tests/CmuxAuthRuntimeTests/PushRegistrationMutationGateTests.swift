import Testing
@testable import CmuxAuthRuntime

@Suite(.serialized) struct PushRegistrationMutationGateTests {
    @Test func cancelledQueuedMutationDoesNotRun() async {
        let gate = PushRegistrationMutationGate()
        let firstStarted = TestPhaseSignal()
        let firstBlocker = TestContinuationBlocker()
        let secondStarted = TestPhaseSignal()

        let first = Task {
            await gate.withLock {
                await firstStarted.markStarted()
                await firstBlocker.wait()
            }
        }
        await firstStarted.waitUntilStarted()

        let second = Task {
            await gate.withLock {
                await secondStarted.markStarted()
            }
        }
        second.cancel()

        await firstBlocker.release()
        await first.value
        _ = await second.value

        #expect(await secondStarted.didStart == false)
    }
}
