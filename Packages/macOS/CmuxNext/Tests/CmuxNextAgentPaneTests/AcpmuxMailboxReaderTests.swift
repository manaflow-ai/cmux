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
        /// Runs inside each call, before it answers (the call's index).
        private let during: @Sendable (Int) -> Void

        init(_ script: [Result<AcpmuxMailboxPage, Refused>], during: @escaping @Sendable (Int) -> Void = { _ in }) {
            self.script = script
            self.during = during
        }

        var cursors: [UInt64] { asked.withLock { $0 } }

        func wait(after cursor: UInt64) throws -> AcpmuxMailboxPage {
            let call = asked.withLock { asked -> Int in
                asked.append(cursor)
                return asked.count - 1
            }
            during(call)
            guard call < script.count else { throw CancellationError() }
            return try script[call].get()
        }

    }

    /// A mailbox whose every call waits until the test releases it with a page.
    nonisolated private final class HeldMailbox: Sendable {
        private let held = Mutex<CheckedContinuation<AcpmuxMailboxPage, Never>?>(nil)
        /// One element per call that is waiting.
        let asked: AsyncStream<Void>
        private let askedContinuation: AsyncStream<Void>.Continuation

        init() {
            let stream = AsyncStream<Void>.makeStream()
            asked = stream.stream
            askedContinuation = stream.continuation
        }

        func wait() async -> AcpmuxMailboxPage {
            await withCheckedContinuation { continuation in
                held.withLock { $0 = continuation }
                askedContinuation.yield()
            }
        }

        func release(_ page: AcpmuxMailboxPage) {
            let continuation = held.withLock { held -> CheckedContinuation<AcpmuxMailboxPage, Never>? in
                defer { held = nil }
                return held
            }
            continuation?.resume(returning: page)
        }
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mailbox-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func page(cursor: UInt64) -> AcpmuxMailboxPage { AcpmuxMailboxPage(messages: [], nextCursor: cursor) }

    /// A reader on `socket` whose retry waits report their delay to `parked`.
    private func makeReader(_ socket: String, _ mailbox: Mailbox, policy: RetryPolicy = .firstConnect,
                            parked: AsyncStream<Duration?>.Continuation) -> (AcpmuxMailboxReader, RetryWake) {
        let wake = RetryWake(owner: "AcpmuxMailboxReaderTests", probe: RetryWakeProbe(parked: { parked.yield($0) }))
        let reader = AcpmuxMailboxReader(socketPath: socket, wake: wake, clock: StoppedClock(), policy: policy) { after in
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

    /// acpmux restarted while an attempt ran, with the timed retries already spent on its stale
    /// socket: the new socket came before the rebaseline that follows the failed attempt, so its
    /// change wakes nothing. It gets timed retries of its own instead of a wait that only an app
    /// activation ends. Before, the reader parked with no timer.
    @Test func aSocketReplacedDuringAnAttemptAfterTheBudgetIsSpentIsRetriedOnATimer() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("acpmux.sock").path
        #expect(FileManager.default.createFile(atPath: socket, contents: Data()))
        let fresh = root.appendingPathComponent("fresh.sock").path
        // The third call fails after acpmux bound its new socket at the same path.
        let mailbox = Mailbox([.failure(Refused()), .failure(Refused()), .failure(Refused())], during: { call in
            guard call == 2 else { return }
            _ = FileManager.default.createFile(atPath: fresh, contents: Data())
            _ = rename(fresh, socket)
        })
        let (parks, parked) = AsyncStream<Duration?>.makeStream()
        // One timed retry: the second failure spends the budget.
        let policy = RetryPolicy(initial: .milliseconds(250), maximum: .seconds(30), timedRetries: 1)
        let (reader, wake) = makeReader(socket, mailbox, policy: policy, parked: parked)
        let run = Task { await reader.run { _ in } }

        var waits = parks.makeAsyncIterator()
        let first = await waits.next() ?? nil
        #expect(first != nil)
        wake.fire()
        let spent = await waits.next()
        #expect(spent == .some(nil), "the stale socket's timed retry was not spent")
        wake.fire()
        let afterReplace = await waits.next() ?? nil
        #expect(afterReplace != nil, "the socket that replaced the stale one during the attempt got no timed retry")
        run.cancel()
        await run.value
    }

    /// A reader that reads keeps no watch on acpmux's folder (each entry change there would wake
    /// the process), and neither does one that ended. Before, the watch armed at the start stayed
    /// for the reader's life and after it.
    @Test func aReaderThatReadsKeepsNoWatch() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("acpmux.sock").path
        #expect(FileManager.default.createFile(atPath: socket, contents: Data()))
        let mailbox = Mailbox([.failure(Refused()), .success(page(cursor: 1))])
        let (parks, parked) = AsyncStream<Duration?>.makeStream()
        let (reader, wake) = makeReader(socket, mailbox, parked: parked)
        let (watched, watchedNow) = AsyncStream<RetryWake.WatchedFile>.makeStream()
        let run = Task { await reader.run { _ in watchedNow.yield(wake.rebaseline()) } }

        var waits = parks.makeAsyncIterator()
        _ = await waits.next()
        guard case .present = wake.rebaseline() else {
            Issue.record("a reader retrying a failed wait did not watch the socket")
            return
        }
        wake.fire()
        var states = watched.makeAsyncIterator()
        let reading = await states.next()
        #expect(reading == .unwatched, "a reader that read a page still watched acpmux's folder")
        await run.value
        #expect(wake.rebaseline() == .unwatched, "a reader that ended still watched acpmux's folder")
    }

    /// A page on its way to the main actor when the owner stops the reader (a sign-out or another
    /// account in the hop) is dropped: the owner's reset runs on the main actor, and the page's
    /// reader is no longer current there. Before, cancelling the task did not stop the page, and
    /// the old account's reports came back after the reset.
    @MainActor @Test func aPageOnItsWayWhenTheReaderStopsIsDropped() async throws {
        let mailbox = HeldMailbox()
        let wake = RetryWake(owner: "AcpmuxMailboxReaderTests")
        let reader = AcpmuxMailboxReader(socketPath: "/nonexistent/acpmux.sock", wake: wake, clock: StoppedClock(),
                                         policy: .firstConnect) { _ in await mailbox.wait() }
        let (pages, delivered) = AsyncStream<AcpmuxMailboxPage>.makeStream()
        let subscription = AcpmuxMailboxSubscription()
        let run = subscription.start(reader) { delivered.yield($0) }
        var asked = mailbox.asked.makeAsyncIterator()
        var received = pages.makeAsyncIterator()

        _ = await asked.next()
        mailbox.release(page(cursor: 1))
        let current = await received.next()
        #expect(current?.nextCursor == 1, "the current reader's page was not delivered")

        _ = await asked.next()
        // Released and stopped in one main-actor turn: the page is on its way when the reader stops.
        mailbox.release(page(cursor: 2))
        subscription.stop()
        await run.value
        delivered.finish()
        var late: [AcpmuxMailboxPage] = []
        while let page = await received.next() { late.append(page) }
        #expect(late.isEmpty, "a stopped reader's page was applied after the reset")
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
