import CmuxControlSocket
import Testing

@Suite("Control command admission")
struct ControlCommandAdmissionTests {
    @Test("Result delivery retains bounded execution and rejects overload")
    func resultDeliveryAndOverload() async {
        let pool = ControlClientWorkerPool(maximumConcurrentJobs: 1, maximumPendingJobs: 0)
        let (started, signalStarted) = AsyncStream<Void>.makeStream()
        let (release, finish) = AsyncStream<Void>.makeStream()
        let first = Task {
            await pool.perform {
                signalStarted.yield(())
                for await _ in release {}
                return 42
            }
        }
        var iterator = started.makeAsyncIterator()
        await iterator.next()
        let rejected = await pool.perform { 99 }
        #expect(rejected == nil)
        #expect(await pool.metrics().activeJobs == 1)
        finish.finish()
        #expect(await first.value == 42)
        signalStarted.finish()
        await pool.stop()
        #expect(await pool.perform { 100 } == nil)
    }

}
