import Foundation
@testable import CmuxNextCloud
import Testing

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudRefreshGateTests {
    @MainActor
    private final class Reads {
        let started = AsyncStream<Int>.makeStream()
        let entered = AsyncStream<Void>.makeStream()
        var releases: [Int: CheckedContinuation<Bool, Never>] = [:]
        var count = 0
        var canceled: [Int: Bool] = [:]

        func read() async -> Bool {
            count += 1
            let number = count
            started.continuation.yield(number)
            let result = await withCheckedContinuation { releases[number] = $0 }
            canceled[number] = Task.isCancelled
            return !Task.isCancelled && result
        }

        func request(_ gate: CloudRefreshGate) -> Task<Bool, Never> {
            Task { @MainActor in
                // No suspension between this event and entering the actor-isolated gate.
                entered.continuation.yield(())
                return await gate.run { await self.read() }
            }
        }

        func release(_ number: Int, result: Bool = true) {
            releases.removeValue(forKey: number)?.resume(returning: result)
        }
    }

    @Test func overlappingTriggersShareTheNextRead() async {
        let gate = CloudRefreshGate(), reads = Reads()
        var entered = reads.entered.stream.makeAsyncIterator()
        var started = reads.started.stream.makeAsyncIterator()
        let first = reads.request(gate)
        _ = await entered.next()
        #expect(await started.next() == 1)
        var followers: [Task<Bool, Never>] = []
        for _ in 0..<8 {
            followers.append(reads.request(gate))
            _ = await entered.next()
        }
        #expect(reads.count == 1)
        reads.release(1)
        #expect(await first.value)
        #expect(await started.next() == 2)
        // A failed fresh answer must not be replaced by the successful first read.
        reads.release(2, result: false)
        for follower in followers { #expect(await follower.value == false) }
        #expect(reads.count == 2)
    }

    @Test func triggerDuringFollowUpGetsAFreshRead() async {
        let gate = CloudRefreshGate(), reads = Reads()
        var entered = reads.entered.stream.makeAsyncIterator()
        var started = reads.started.stream.makeAsyncIterator()
        let first = reads.request(gate)
        _ = await entered.next()
        #expect(await started.next() == 1)
        let second = reads.request(gate)
        _ = await entered.next()
        reads.release(1)
        #expect(await first.value)
        #expect(await started.next() == 2)
        let third = reads.request(gate)
        _ = await entered.next()
        #expect(reads.count == 2)
        reads.release(2)
        #expect(await second.value)
        #expect(await started.next() == 3)
        reads.release(3)
        #expect(await third.value)
    }

    @Test func cancelingOneWaiterKeepsTheSharedRead() async {
        let gate = CloudRefreshGate(), reads = Reads()
        var entered = reads.entered.stream.makeAsyncIterator()
        var started = reads.started.stream.makeAsyncIterator()
        let first = reads.request(gate)
        _ = await entered.next()
        _ = await started.next()
        let canceled = reads.request(gate)
        _ = await entered.next()
        let surviving = reads.request(gate)
        _ = await entered.next()
        canceled.cancel()
        reads.release(1)
        _ = await first.value
        #expect(await started.next() == 2)
        reads.release(2)
        #expect(await surviving.value)
        #expect(await canceled.value == false)
        #expect(reads.canceled[2] == false)
    }

    @Test func stopCancelsRunningAndQueuedReads() async {
        let gate = CloudRefreshGate(), reads = Reads()
        var entered = reads.entered.stream.makeAsyncIterator()
        var started = reads.started.stream.makeAsyncIterator()
        let first = reads.request(gate)
        _ = await entered.next()
        _ = await started.next()
        let second = reads.request(gate)
        _ = await entered.next()
        gate.cancel()
        reads.release(1)
        #expect(await first.value == false)
        #expect(await second.value == false)
        #expect(reads.count == 1)
        #expect(reads.canceled[1] == true)
        let restarted = reads.request(gate)
        _ = await entered.next()
        #expect(await started.next() == 2)
        reads.release(2)
        #expect(await restarted.value)
    }

    @Test func unavailableStateIsRecheckedByTheQueuedOperation() async {
        let gate = CloudRefreshGate(), reads = Reads()
        var entered = reads.entered.stream.makeAsyncIterator()
        var started = reads.started.stream.makeAsyncIterator()
        let first = reads.request(gate)
        _ = await entered.next()
        _ = await started.next()
        var available = true
        let queued = Task { @MainActor in
            reads.entered.continuation.yield(())
            return await gate.run {
                guard available else { return false }
                return await reads.read()
            }
        }
        _ = await entered.next()
        available = false
        reads.release(1)
        #expect(await first.value)
        #expect(await queued.value == false)
        #expect(reads.count == 1)
    }
}
