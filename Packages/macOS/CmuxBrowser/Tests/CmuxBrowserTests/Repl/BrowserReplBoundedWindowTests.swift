import Foundation
import Testing

@testable import CmuxBrowser

/// A page-world `frame.evaluate` opens the session's action window (what
/// the page opens goes to the session), but a long evaluation, or the
/// runtime's polling, must not keep it open: the user's own dialogs and
/// popups in that tab would go to the agent meanwhile. The window closes
/// when the call returns or after a bound, whichever comes first.
@MainActor
@Suite("Browser REPL bounded action window")
struct BrowserReplBoundedWindowTests {
    private struct ElapsedSleeper: BrowserReplSleeping {
        func sleep(for duration: Duration) async throws {}
    }

    private struct DistantSleeper: BrowserReplSleeping {
        func sleep(for duration: Duration) async throws {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    @Test func theWindowClosesAtTheBoundWhileTheCallStillRuns() async {
        var begins = 0
        var ends = 0
        let (closed, signal) = AsyncStream.makeStream(of: Void.self)
        let window = BrowserReplBoundedWindow(limit: .seconds(1), sleeper: ElapsedSleeper())
        let value = await window.run(
            begin: { begins += 1 },
            end: {
                ends += 1
                signal.yield()
            }
        ) {
            // The call outlasts the bound: it ends only once the window closed.
            var iterator = closed.makeAsyncIterator()
            _ = await iterator.next()
            return ends
        }
        #expect(value == 1, "the window closed before the call returned")
        #expect(begins == 1)
        #expect(ends == 1, "closed once")
    }

    @Test func theWindowClosesWhenTheCallReturnsFirst() async throws {
        var ends = 0
        let window = BrowserReplBoundedWindow(limit: .seconds(1), sleeper: DistantSleeper())
        let value = try await window.run(begin: {}, end: { ends += 1 }) { () async throws -> Int in
            #expect(ends == 0, "open while the call runs")
            return 7
        }
        #expect(value == 7)
        #expect(ends == 1)
    }

    @Test func aThrowingCallClosesTheWindow() async {
        struct Failed: Error {}
        var ends = 0
        let window = BrowserReplBoundedWindow(limit: .seconds(1), sleeper: DistantSleeper())
        await #expect(throws: Failed.self) {
            try await window.run(begin: {}, end: { ends += 1 }) { () async throws -> Int in throw Failed() }
        }
        #expect(ends == 1)
    }
}
