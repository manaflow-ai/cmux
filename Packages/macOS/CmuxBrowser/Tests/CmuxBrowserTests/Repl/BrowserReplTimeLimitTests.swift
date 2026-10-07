import Foundation
import Testing

@testable import CmuxBrowser

/// A driver call with a time limit (`tab.navigate`'s wait, a timed
/// `frame.evaluate`) runs its work in a task of its own. A call that ended
/// (its limit passed, or the cell that made it was cancelled) must not keep
/// acting: its work is cancelled, so every later step that checks for
/// cancellation (the frame gate's ``BrowserReplFrameGate/checkTab(in:)``)
/// stops before it reaches the tab.
@MainActor
@Suite("Browser REPL call time limit")
struct BrowserReplTimeLimitTests {
    private struct ElapsedSleeper: BrowserReplSleeping {
        func sleep(for duration: Duration) async throws {}
    }

    private struct DistantSleeper: BrowserReplSleeping {
        func sleep(for duration: Duration) async throws {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    /// Work that waits for `resume`, then acts unless it was cancelled, and
    /// reports on `finished` either way.
    @MainActor
    private final class Work {
        var acted = false
        let (resumed, resume) = AsyncStream.makeStream(of: Void.self)
        let (ended, finish) = AsyncStream.makeStream(of: Void.self)

        func body() async {
            var waiting = resumed.makeAsyncIterator()
            _ = await waiting.next()
            if !Task.isCancelled { acted = true }
            finish.yield()
        }

        /// Lets the work go on and waits until it is done.
        func release() async {
            resume.yield()
            var done = ended.makeAsyncIterator()
            _ = await done.next()
        }
    }

    /// r26: the helper cancelled its work only after its result came back,
    /// which a timeout throws past, so a timed-out call kept acting.
    @Test("A call whose limit passed cancels its work, which then does not act")
    func aTimedOutCallCancelsItsWork() async {
        let work = Work()
        let limit = BrowserReplTimeLimit(sleeper: ElapsedSleeper())
        var code: String?
        do {
            try await limit.run(milliseconds: 5, what: "waiting") { await work.body() }
        } catch {
            code = (error as? BrowserReplDriverError)?.code
        }
        #expect(code == "timeout")
        await work.release()
        #expect(!work.acted, "the timed-out call's work acted after the call ended")
    }

    @Test("A cancelled call cancels its work, which then does not act")
    func aCancelledCallCancelsItsWork() async {
        let work = Work()
        let limit = BrowserReplTimeLimit(sleeper: DistantSleeper())
        let call = Task { @MainActor in
            try await limit.run(milliseconds: 60_000, what: "waiting") { await work.body() }
        }
        call.cancel()
        await work.release()
        _ = await call.result
        #expect(!work.acted, "the cancelled call's work acted after the call ended")
    }

    @Test("Work that finishes in time returns its value")
    func workInTimeReturnsItsValue() async throws {
        let limit = BrowserReplTimeLimit(sleeper: DistantSleeper())
        let value = try await limit.run(milliseconds: 60_000, what: "") { 7 }
        #expect(value == 7)
    }
}
