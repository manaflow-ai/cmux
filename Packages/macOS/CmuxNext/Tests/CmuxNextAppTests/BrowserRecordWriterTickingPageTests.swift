@testable import CmuxNextBrowser
import CmuxNextBrowserHistory
import Foundation
import Testing

/// A page that keeps changing (a title ticking faster than the write delay)
/// still gets its record written: the first change opens one delay window
/// and its end writes the latest state. The debounce restarted on every
/// change, so a ticking page's address, title and history were never
/// written until the tab closed, and a crash lost them (QA spree 2026-10-21).
@MainActor @Suite(.timeLimit(.minutes(1))) struct BrowserRecordWriterTickingPageTests {
    /// Sleeps that end only when the test lets them.
    @MainActor final class Gate {
        var waiting: [CheckedContinuation<Void, Never>] = []
        func sleep() async { await withCheckedContinuation { waiting.append($0) } }
        func release() { let all = waiting; waiting = []; all.forEach { $0.resume() } }
    }

    @Test func aTickingTitleStillWritesWithinOneWindow() async throws {
        let page = MockBrowserEngine().makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://old.example/")))
        let gate = Gate()
        var sent: [BrowserRecordUpdate] = []
        let writer = BrowserRecordWriter(tab: page, recorded: BrowserRecord(url: "https://old.example/", title: "Old"),
                                         delay: .milliseconds(500), sleep: { _ in await gate.sleep() },
                                         send: { sent.append($0); return true })
        defer { writer.cancel() }
        let next = try #require(URL(string: "https://ticker.example/"))
        let id = page.makeNavigationID()
        page.simulate(.started(id, url: next))
        page.simulate(.committed(id, url: next))
        // Ticks keep coming while the window is open.
        for tick in 0..<20 {
            page.simulate(.titleChanged("tick \(tick)"))
            await Task.yield()
        }
        try await waitUntil { !gate.waiting.isEmpty }
        #expect(gate.waiting.count == 1, "each change restarted the write: \(gate.waiting.count) windows")
        gate.release()
        try await waitUntil { !sent.isEmpty }
        #expect(sent.first?.url == "https://ticker.example/")
        #expect(sent.first?.title?.hasPrefix("tick") == true)
    }

    private func waitUntil(_ done: @MainActor () -> Bool) async throws {
        for _ in 0..<2000 where !done() { await Task.yield() }
        try #require(done())
    }
}
