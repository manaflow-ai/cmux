import Testing
@testable import CmuxNextMobile

@Suite struct MobileHostQueueTests {
    @Test(.timeLimit(.minutes(1))) func aThousandPairingEventsWaitForTheConsumer() async {
        let queue = MobileHostQueue<Int>(capacity: 32)
        let (filled, signal) = AsyncStream<Void>.makeStream()
        let producer = Task {
            for index in 0..<1000 {
                await queue.send(index)
                if index == 31 { signal.yield(); signal.finish() }
            }
            queue.finish()
        }
        for await _ in filled { break }
        var received: [Int] = []
        for await value in queue.stream { received.append(value) }
        await producer.value
        #expect(received == Array(0..<1000))
    }

    @Test(.timeLimit(.minutes(1))) func cancellingABackpressuredPairingSendAllowsTheNextRun() async {
        let queue = MobileHostQueue<Int>(capacity: 1)
        await queue.send(1)
        let waiting = Task { await queue.send(2) }
        waiting.cancel()
        await waiting.value
        var values = queue.stream.makeAsyncIterator()
        #expect(await values.next() == 1)
        await queue.send(3)
        #expect(await values.next() == 3)
        queue.finish()
        #expect(await values.next() == nil)
    }

}
