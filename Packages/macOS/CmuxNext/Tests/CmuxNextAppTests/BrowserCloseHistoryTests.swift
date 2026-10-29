import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextDaemon
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
        /// The tab record's url writes (`frontend_browser_tabs.url`).
        var recordURLs: [String] = []
        var fetched = false
    }

    static let a = URL(string: "https://example.com/a")!
    static let b = URL(string: "https://example.com/b")!

    /// A frontend browser tab showing `a`, tracked by a service whose
    /// navigation write-back waits an hour (only the close can write).
    static func tracked(_ daemon: Daemon, store: @escaping @MainActor () async -> Bool = { true })
        async throws -> (BrowserTabService, MockBrowserTab, TabModel)
    {
        let service = BrowserTabService(daemon: DaemonService(), cef: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()))
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 7), kind: .browser, url: a.absoluteString,
                                       browserRenderer: "frontend", browserEngine: "cef"))
        service.tabModel = { $0 == tab.id ? tab : nil }
        service.writeBackDelay = .seconds(3600)
        service.update = { _, _, update in
            if let url = update.url { daemon.recordURLs.append(url) }
            return true
        }
        service.fetchHistory = { _, _ in daemon.fetched = true; return nil }
        service.storeHistory = { _, _, history in
            let ok = await store()
            if ok { daemon.stored.append(history) }
            return ok
        }
        let page = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: a))
        service.track(page, for: tab)
        // The history writer starts on a turn after the daemon answers; a
        // fixed number of turns is not enough on a loaded machine.
        let deadline = ContinuousClock.now + .seconds(5)
        while service.historyWriters[tab.id] == nil, ContinuousClock.now < deadline { await Task.yield() }
        try #require(daemon.fetched && service.historyWriters[tab.id] != nil, "the history writer never started")
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
        // Reopen Closed restores the history only at the record's page: the
        // two must agree, or a relaunch reopens `a` with no history at all.
        #expect(daemon.recordURLs.last == Self.b.absoluteString, "the record still names the page before")
    }

    /// Quit and close send the page as it is now, even a navigation the
    /// record writer has not been told of yet (it hears of page changes on a
    /// later turn, so Cmd-W at once found nothing to send).
    @Test func aFlushRightAfterANavigationSendsIt() async throws {
        let daemon = Daemon()
        let (service, page, tab) = try await Self.tracked(daemon)
        page.load(Self.b)
        await service.writers[tab.id]?.flushNow()
        #expect(daemon.recordURLs.last == Self.b.absoluteString, "the flush sent nothing: it had not heard of the navigation")
    }

    /// The close command's step (`DaemonService.prepareClose`, set to this)
    /// reaches the page by its surface on its machine. Called on the service:
    /// the hook is process-wide, and other suites' app services replace it.
    @Test func theCloseCommandSavesThePageOfItsSurface() async throws {
        let daemon = Daemon()
        let (service, page, tab) = try await Self.tracked(daemon)
        page.load(Self.b)
        await service.flushHistory(machine: "other-machine", surfaces: [tab.surface])
        #expect(daemon.stored.isEmpty, "a close on another machine saved this page")
        await service.flushHistory(machine: "local", surfaces: [tab.surface])
        #expect(daemon.stored.last.map { $0.entries[$0.index].url } == Self.b.absoluteString)
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
