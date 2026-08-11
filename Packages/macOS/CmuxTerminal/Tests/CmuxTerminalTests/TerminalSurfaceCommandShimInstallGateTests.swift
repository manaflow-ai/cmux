import Foundation
import Testing
@testable import CmuxTerminal

@Suite("Terminal surface command shim install gate")
struct TerminalSurfaceCommandShimInstallGateTests {
    @Test("The waiter limit rejects excess restore work")
    func waiterLimitRejectsExcessRestoreWork() async throws {
        let gate = TerminalSurfaceCommandShimInstallGate(maximumWaiterCount: 1)
        let activeToken = try #require(await gate.acquire())
        let queuedEvents = AsyncStream<Void>.makeStream()
        var queuedEventIterator = queuedEvents.stream.makeAsyncIterator()
        let queued = Task {
            await gate.acquire {
                queuedEvents.continuation.yield()
            }
        }

        _ = await queuedEventIterator.next()
        #expect(await gate.acquire() == nil)

        queued.cancel()
        #expect(await queued.value == nil)
        gate.release(activeToken)
    }
}
