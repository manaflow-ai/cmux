import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
import Testing

/// cx-d0d.73: closing a browser tab (Cmd-W) saves its page's newest history
/// and scroll position first. The daemon copies the stored history into
/// Reopen Closed at the close and then deletes it, so a navigation still in
/// the write-back debounce, or a scroll measured only at quit, was lost.
@MainActor
@Suite(.serialized)
struct BrowserCloseHistoryTests {
    final class Daemon {
        var stored: [FrontendBrowserHistory] = []
        var fetched = false
    }

    static let a = URL(string: "https://example.com/a")!
    static let b = URL(string: "https://example.com/b")!

    /// A frontend browser tab showing `a`, tracked by a service whose
    /// navigation write-back waits an hour (only the close can write).
    static func tracked(_ daemon: Daemon, store: @escaping @MainActor () async -> Bool = { true })
        async throws -> (BrowserTabService, MockBrowserTab, TabModel)
    {
        let service = BrowserTabService(daemon: DaemonService(), cef: CEFEngine(layout: nil))
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 7), kind: .browser, url: a.absoluteString,
                                       browserRenderer: "frontend", browserEngine: "cef"))
        service.tabModel = { $0 == tab.id ? tab : nil }
        service.writeBackDelay = .seconds(3600)
        service.update = { _, _, _ in true }
        service.fetchHistory = { _, _ in daemon.fetched = true; return nil }
        service.storeHistory = { _, _, history in
            let ok = await store()
            if ok { daemon.stored.append(history) }
            return ok
        }
        let page = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: a))
        service.track(page, for: tab)
        let deadline = ContinuousClock.now + .seconds(5)
        while !daemon.fetched, ContinuousClock.now < deadline { await Task.yield() }
        // The history writer starts on the turn after the daemon answers.
        for _ in 0 ..< 20 { await Task.yield() }
        return (service, page, tab)
    }

    @Test func closingATabSavesItsLastNavigationAndScrollBeforeTheClose() async throws {
        let daemon = Daemon()
        let (service, page, tab) = try await Self.tracked(daemon)
        // The user goes on to `b` and scrolls, then presses Cmd-W at once.
        page.load(Self.b)
        page.scrollPosition = { 640 }
        await service.flushHistory([tab.id], within: .seconds(2))
        service.untrack(tab.id)

        let saved = try #require(daemon.stored.last, "the close saved nothing")
        let shown = try #require(saved.entries.indices.contains(saved.index) ? saved.entries[saved.index] : nil)
        #expect(shown.url == Self.b.absoluteString, "the navigation in the debounce was lost")
        #expect(shown.scrollY == 640, "the scroll position was not measured at the close")
    }

    @Test func aDaemonThatDoesNotAnswerHoldsTheCloseOnlyBriefly() async throws {
        let daemon = Daemon()
        let (service, page, tab) = try await Self.tracked(daemon, store: {
            try? await Task.sleep(for: .seconds(30))
            return false
        })
        page.load(Self.b)
        let started = ContinuousClock.now
        await service.flushHistory([tab.id], within: .milliseconds(300))
        service.untrack(tab.id)
        #expect(ContinuousClock.now - started < .seconds(2), "the close waited on the daemon")
    }
}
