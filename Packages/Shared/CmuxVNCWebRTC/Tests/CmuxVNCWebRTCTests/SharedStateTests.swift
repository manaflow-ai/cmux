@testable import CmuxVNCWebRTC
import CmuxVNC
import Foundation
import Testing

/// The state the data channel, the signaling tasks and the
/// readers share is behind CmuxSafeConcurrency's Mutex (checked Sendable),
/// not an unchecked lock. These pin the behavior the conversions keep.
struct ByteInboxTests {
    @Test func deliversInOrderFromAnotherThread() async {
        let inbox = ByteInbox()
        let total = 5_000
        let producer = Thread {
            for index in 0 ..< total { inbox.yield(Data([UInt8(truncatingIfNeeded: index)])) }
            inbox.finish()
        }
        producer.start()
        var received: [UInt8] = []
        while let chunk = await inbox.next() { received.append(contentsOf: chunk) }
        #expect(received == (0 ..< total).map { UInt8(truncatingIfNeeded: $0) })
    }

    @Test func finishDeliversWhatIsQueuedThenEnds() async {
        let inbox = ByteInbox()
        inbox.yield(Data([1]))
        inbox.yield(Data([2]))
        inbox.finish()
        inbox.yield(Data([3]))
        #expect(await inbox.next() == Data([1]))
        #expect(await inbox.next() == Data([2]))
        #expect(await inbox.next() == nil)
        #expect(await inbox.next() == nil)
    }

    @Test func aWaitingReaderGetsTheNextChunk() async {
        let inbox = ByteInbox()
        let reader = Task { await inbox.next() }
        // Whether the reader is already waiting or not, it gets this chunk.
        inbox.yield(Data([7]))
        #expect(await reader.value == Data([7]))
    }

    @Test func cancellingTheReaderEndsTheInbox() async {
        let inbox = ByteInbox()
        let reader = Task { await inbox.next() }
        reader.cancel()
        #expect(await reader.value == nil)
        inbox.yield(Data([1]))
        #expect(await inbox.next() == nil)
    }
}

struct OpenSignalTests {
    @Test func aFireBeforeTheWaitResolvesIt() async throws {
        let signal = OpenSignal()
        signal.fire(nil)
        try await signal.wait(timeout: 30)
    }

    @Test func theFirstFireWins() async {
        let signal = OpenSignal()
        signal.fire(RFBError.connectionClosed)
        signal.fire(nil)
        await #expect(throws: RFBError.self) { try await signal.wait(timeout: 30) }
    }

    @Test func aFireFromAnotherThreadWakesTheWaiter() async throws {
        let signal = OpenSignal()
        let firing = Thread { signal.fire(nil) }
        firing.start()
        try await signal.wait(timeout: 30)
    }
}
