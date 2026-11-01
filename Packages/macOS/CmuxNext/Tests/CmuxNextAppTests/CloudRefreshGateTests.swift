import Foundation
import Testing
@testable import CmuxNextApp

@MainActor @Suite(.serialized)
struct CloudRefreshGateTests {
    @Test func concurrentRefreshesShareOneRead() async {
        let gate = CloudRefreshGate()
        let started = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<Void, Never>?
        var reads = 0

        let first = Task { @MainActor in
            await gate.run {
                reads += 1
                started.continuation.yield(())
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    release = continuation
                }
            }
        }

        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        let second = Task { @MainActor in
            await gate.run { reads += 1 }
        }
        await Task.yield()
        #expect(reads == 1)

        release?.resume()
        await first.value
        await second.value
        #expect(reads == 2, "a trigger during a read gets one coalesced follow-up")
    }
}
