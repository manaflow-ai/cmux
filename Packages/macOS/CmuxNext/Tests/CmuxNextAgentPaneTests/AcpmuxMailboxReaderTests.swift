@testable import CmuxNextAgentPane
import CmuxNextCompat
@testable import CmuxNextDaemon
import Foundation
import Testing

/// The Feed's reports reader retries on the shared daemon-client path (``RetryPacer`` and
/// ``RetryWake``), not a sleep: acpmux not running (its socket and folder missing) arms no timer
/// and wakes when the socket appears; a stale socket (acpmux crashed, the file stayed) is paced
/// and wakes when acpmux replaces it; a page resets the pacing. The retry clock never runs, so
/// only those events can end a wait. Before, the reader slept 5 s per failed wait, then waited for
/// the socket file only while it was missing and slept up to 30 s while a stale one stayed.
@Suite(.timeLimit(.minutes(1))) struct AcpmuxMailboxReaderTests {
    nonisolated private struct Refused: Error {}

    /// The mailbox: answers each call from `script` in turn (the cursor it was asked for is
    /// recorded), then ends the reader (a cancellation).
    nonisolated private final class Mailbox: Sendable {
        private let script: [Result<AcpmuxMailboxPage, Refused>]
        private let asked = Mutex<[UInt64]>([])

        init(_ script: [Result<AcpmuxMailboxPage, Refused>]) {
            self.script = script
        }

        var cursors: [UInt64] { asked.withLock { $0 } }

        func wait(after cursor: UInt64) throws -> AcpmuxMailboxPage {
            let call = asked.withLock { asked -> Int in
                asked.append(cursor)
                return asked.count - 1
            }
            guard call < script.count else { throw CancellationError() }
            return try script[call].get()
        }

    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mailbox-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func page(cursor: UInt64) -> AcpmuxMailboxPage { AcpmuxMailboxPage(messages: [], nextCursor: cursor) }

    /// A reader on `socket` whose retry waits report their delay to `parked`.
    private func makeReader(_ socket: String, _ mailbox: Mailbox,
                            parked: AsyncStream<Duration?>.Continuation) -> (AcpmuxMailboxReader, RetryWake) {
        let wake = RetryWake(owner: "AcpmuxMailboxReaderTests", probe: RetryWakeProbe(parked: { parked.yield($0) }))
        let reader = AcpmuxMailboxReader(socketPath: socket, wake: wake, clock: StoppedClock(), policy: .firstConnect) { after in
            try mailbox.wait(after: after)
        }
        return (reader, wake)
    }

    @Test func aMissingSocketArmsNoTimerAndWakesWhenItAppears() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let socket = home.appendingPathComponent("acpmux.sock").path
        let mailbox = Mailbox([.failure(Refused()), .success(page(cursor: 7))])
        let (parks, parked) = AsyncStream<Duration?>.makeStream()
        let (pages, delivered) = AsyncStream<AcpmuxMailboxPage>.makeStream()
        let (reader, _) = makeReader(socket, mailbox, parked: parked)
        let run = Task { await reader.run { delivered.yield($0) } }

        var waits = parks.makeAsyncIterator()
        let firstWait = await waits.next()
        let delay = try #require(firstWait)
        #expect(delay == nil, "acpmux not running armed a retry timer (\(String(describing: delay)))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        #expect(FileManager.default.createFile(atPath: socket, contents: Data()))

        var received = pages.makeAsyncIterator()
        let delivery = await received.next()
        #expect(delivery?.nextCursor == 7)
        await run.value
        #expect(mailbox.cursors == [0, 0, 7])
    }

    @Test func aStaleSocketIsPacedAndRetriedWhenAcpmuxReplacesIt() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("acpmux.sock").path
        #expect(FileManager.default.createFile(atPath: socket, contents: Data()))
        let mailbox = Mailbox([.failure(Refused()), .success(page(cursor: 3))])
        let (parks, parked) = AsyncStream<Duration?>.makeStream()
        let (pages, delivered) = AsyncStream<AcpmuxMailboxPage>.makeStream()
        let (reader, _) = makeReader(socket, mailbox, parked: parked)
        let run = Task { await reader.run { delivered.yield($0) } }

        var waits = parks.makeAsyncIterator()
        let firstWait = await waits.next()
        let delay = try #require(firstWait)
        #expect(delay != nil, "a socket that exists but refused was not paced")
        // acpmux restarts: it binds a new socket at the same path (a new file renamed over the old).
        let fresh = root.appendingPathComponent("fresh.sock").path
        #expect(FileManager.default.createFile(atPath: fresh, contents: Data()))
        #expect(rename(fresh, socket) == 0)

        var received = pages.makeAsyncIterator()
        let delivery = await received.next()
        #expect(delivery?.nextCursor == 3, "the replaced socket did not wake the paced retry")
        await run.value
        #expect(mailbox.cursors == [0, 0, 3])
    }

    @Test func aPageResetsThePacing() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("acpmux.sock").path
        #expect(FileManager.default.createFile(atPath: socket, contents: Data()))
        let mailbox = Mailbox([.failure(Refused()), .failure(Refused()), .success(page(cursor: 1)), .failure(Refused())])
        let (parks, parked) = AsyncStream<Duration?>.makeStream()
        let (reader, wake) = makeReader(socket, mailbox, parked: parked)
        let run = Task { await reader.run { _ in } }

        // Each paced wait is ended by an explicit event (the clock never runs).
        var delays: [Duration] = []
        var waits = parks.makeAsyncIterator()
        for _ in 0..<3 {
            let next = await waits.next() ?? nil
            delays.append(try #require(next))
            wake.fire()
        }
        await run.value
        // firstConnect: 250 ms, then 500 ms (each within the 20% jitter); after the page, 250 ms again.
        #expect(delays[0] <= .milliseconds(300) && delays[1] >= .milliseconds(400), "the second failure was not spaced further")
        #expect(delays[2] <= .milliseconds(300), "a page did not reset the pacing (\(delays[2]))")
    }
}

/// A clock that never fires: a retry timer on it waits until the task is cancelled.
nonisolated private struct StoppedClock: Clock {
    nonisolated struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        // wakeup-allow: a test clock that never fires; the timer's cancellation ends this sleep
        while true { try await Task.sleep(for: .seconds(3600)) }
    }
}
