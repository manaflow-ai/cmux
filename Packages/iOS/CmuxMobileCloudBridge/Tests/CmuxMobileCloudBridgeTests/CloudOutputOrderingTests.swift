import Foundation
import Testing

@testable import CmuxMobileCloudBridge

/// The ordered hand-off from the daemon's callback threads to the main actor.
///
/// Terminal bytes are only meaningful in the order the daemon produced them: a
/// reordered chunk splits an escape sequence and corrupts the screen. The
/// bridge therefore yields events into one stream per machine and drains that
/// stream with a single consumer, rather than starting an unstructured task per
/// event, which has no ordering guarantee.
struct CloudOutputOrderingTests {
    @Test("Events yielded from many threads arrive in yield order")
    func yieldOrderIsPreserved() async {
        let (events, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .unbounded)
        let count = 2_000

        // Yield from a background thread while the consumer runs, the shape the
        // library's callback has.
        let producer = Task.detached {
            for value in 0..<count {
                continuation.yield(value)
            }
            continuation.finish()
        }

        var received: [Int] = []
        received.reserveCapacity(count)
        for await value in events {
            received.append(value)
        }
        await producer.value

        #expect(received.count == count)
        #expect(received == Array(0..<count))
    }

    @Test("A buffered stream drops nothing when the consumer is slower")
    func slowConsumerKeepsEveryEvent() async {
        let (events, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .unbounded)
        for value in 0..<500 {
            continuation.yield(value)
        }
        continuation.finish()

        var received: [Int] = []
        for await value in events {
            received.append(value)
            // Yield the executor between elements so the producer would have
            // been able to overtake an unbuffered hand-off.
            await Task.yield()
        }

        #expect(received == Array(0..<500))
    }
}
