import Foundation
import Observation
import os
import Testing
@testable import CmuxStatusBar

/// Reports every relaunch wait on `events`. The first `freeWaits` return at
/// once; later ones park until the feed cancels them.
private final class SteppedClock: StatusBarRelaunchClock {
    enum Event: Equatable, Sendable {
        case wait(Duration)
        case cancelled
    }

    let events: AsyncStream<Event>
    private let eventsContinuation: AsyncStream<Event>.Continuation
    private let freeWaits: OSAllocatedUnfairLock<Int>

    init(freeWaits: Int = 0) {
        (events, eventsContinuation) = AsyncStream<Event>.makeStream()
        self.freeWaits = OSAllocatedUnfairLock(initialState: freeWaits)
    }

    func sleep(for duration: Duration) async throws {
        eventsContinuation.yield(.wait(duration))
        let free = freeWaits.withLock { remaining in
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        if free { return }
        // Iteration ends when the waiting task is cancelled.
        let (parked, parkedContinuation) = AsyncStream<Never>.makeStream()
        for await _ in parked {}
        withExtendedLifetime(parkedContinuation) {}
        eventsContinuation.yield(.cancelled)
        throw CancellationError()
    }
}

@MainActor
@Suite("Status bar command feed", .timeLimit(.minutes(1)))
struct StatusBarFeedTests {
    private func shownText(_ feed: StatusBarFeed) -> String? {
        guard case .line(let segments) = feed.content else { return nil }
        return segments.flatMap(\.runs).map(\.text).joined()
    }

    /// Resumes after the next write to `feed.content`.
    private func contentChange(_ feed: StatusBarFeed) async {
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = feed.content
            } onChange: {
                continuation.resume()
            }
        }
    }

    private func counterFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cmux-status-bar-\(UUID().uuidString)")
    }

    @Test func lastLineWithoutNewlineIsShownWhenTheCommandExits() async {
        let clock = SteppedClock()
        var events = clock.events.makeAsyncIterator()
        let feed = StatusBarFeed(clock: clock)
        feed.run("printf 'first\\nlast'")
        #expect(await events.next() == .wait(.seconds(10)))
        #expect(shownText(feed) == "last")
        feed.run("")
        #expect(await events.next() == .cancelled)
    }

    @Test func oneShotCommandWithoutNewlineIsNotReportedAsSilent() async {
        let clock = SteppedClock()
        var events = clock.events.makeAsyncIterator()
        let feed = StatusBarFeed(clock: clock)
        feed.run("printf only")
        #expect(await events.next() == .wait(.seconds(10)))
        #expect(shownText(feed) == "only")
        feed.run("")
        #expect(await events.next() == .cancelled)
    }

    @Test func commandThatPrintsNothingIsReported() async {
        let clock = SteppedClock()
        var events = clock.events.makeAsyncIterator()
        let feed = StatusBarFeed(clock: clock)
        feed.run("true")
        #expect(await events.next() == .wait(.seconds(10)))
        #expect(feed.content == .silentExit)
        feed.run("")
        #expect(await events.next() == .cancelled)
    }

    @Test func exitedCommandStartsAgainAfterTheDelay() async {
        let counter = counterFile()
        defer { try? FileManager.default.removeItem(at: counter) }
        let clock = SteppedClock(freeWaits: 1)
        var events = clock.events.makeAsyncIterator()
        let feed = StatusBarFeed(clock: clock, relaunchDelay: .seconds(3))
        feed.run("echo x >> '\(counter.path)'; wc -l < '\(counter.path)' | tr -d ' '")
        #expect(await events.next() == .wait(.seconds(3)))
        #expect(await events.next() == .wait(.seconds(3)))
        #expect(shownText(feed) == "2")
        feed.run("")
        #expect(await events.next() == .cancelled)
    }

    @Test func clearingTheCommandCancelsThePendingRelaunch() async throws {
        let counter = counterFile()
        defer { try? FileManager.default.removeItem(at: counter) }
        let clock = SteppedClock()
        var events = clock.events.makeAsyncIterator()
        let feed = StatusBarFeed(clock: clock)
        feed.run("echo x >> '\(counter.path)'; echo started")
        #expect(await events.next() == .wait(.seconds(10)))
        feed.run("")
        #expect(await events.next() == .cancelled)
        #expect(feed.content == .hidden)
        #expect(try String(contentsOf: counter, encoding: .utf8) == "x\n")
    }

    @Test func refreshRequestReachesTheCommand() async {
        let clock = SteppedClock()
        let feed = StatusBarFeed(clock: clock)
        feed.run("echo 1; read _; echo 2; read _")
        await contentChange(feed)
        #expect(shownText(feed) == "1")
        feed.requestRefresh()
        await contentChange(feed)
        #expect(shownText(feed) == "2")
        feed.run("")
    }
}
