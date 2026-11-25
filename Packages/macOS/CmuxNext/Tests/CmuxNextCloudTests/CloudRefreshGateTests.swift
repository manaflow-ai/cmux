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

        func request(_ gate: CloudRefreshGate?) -> Task<Bool, Never> {
            Task { @MainActor in
                // No suspension between this event and entering the actor-isolated gate.
                entered.continuation.yield(())
                if let gate { return await gate.run { await self.read() } }
                return await read()
            }
        }

        func release(_ number: Int, result: Bool = true) {
            releases.removeValue(forKey: number)?.resume(returning: result)
        }
    }

    @Test(arguments: [false, true])
    func overlappingTriggersShareTheNextRead(coalesced: Bool) async {
        let gate: CloudRefreshGate? = coalesced ? CloudRefreshGate() : nil
        let reads = Reads()
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
        #expect(reads.count == (coalesced ? 1 : 9))
        reads.release(1)
        #expect(await first.value)
        #expect(await started.next() == 2)
        // A failed fresh answer must not be replaced by the successful first read.
        for number in 2...(coalesced ? 2 : 9) { reads.release(number, result: false) }
        for follower in followers { #expect(await follower.value == false) }
        #expect(reads.count == (coalesced ? 2 : 9))
        print("Cloud refresh burst: coalesced=\(coalesced), requests=\(reads.count)")
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

    private func expectPromptCancellation(_ task: Task<Bool, Never>) async {
        let returned = AsyncStream<Bool>.makeStream()
        let observer = Task { returned.continuation.yield(await task.value == false) }
        // A deadline reports a failure without leaving the held read wedged on the old gate.
        let deadline = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { returned.continuation.yield(false) }
        }
        var result = returned.stream.makeAsyncIterator()
        #expect(await result.next() == true, "Canceled waiter must return before the read is released")
        deadline.cancel()
        observer.cancel()
    }

    @Test(arguments: [false, true])
    func cancelingOneWaiterKeepsTheSharedRead(running: Bool) async {
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
        if running {
            reads.release(1)
            #expect(await first.value)
            #expect(await started.next() == 2)
        }
        canceled.cancel()
        await expectPromptCancellation(canceled)
        if !running {
            reads.release(1)
            #expect(await first.value)
            #expect(await started.next() == 2)
        }
        reads.release(2)
        #expect(await surviving.value)
        #expect(await canceled.value == false)
        #expect(reads.canceled[2] == false)
    }

    @Test func cancelingLastWaiterKeepsRestartBehindTheRead() async {
        let gate = CloudRefreshGate(), reads = Reads()
        var entered = reads.entered.stream.makeAsyncIterator()
        var started = reads.started.stream.makeAsyncIterator()
        let canceled = reads.request(gate)
        _ = await entered.next()
        #expect(await started.next() == 1)
        canceled.cancel()
        await expectPromptCancellation(canceled)
        let restarted = reads.request(gate)
        _ = await entered.next()
        #expect(reads.count == 1)
        reads.release(1)
        #expect(await started.next() == 2)
        #expect(reads.canceled[1] == true)
        reads.release(2)
        #expect(await restarted.value)
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
