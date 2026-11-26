import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// PACING TRIAGE #32910 (120 Hz films of Cmd-T, feat 585171513e37): each Cmd-T dropped 4-17 refreshes in the 50-150 ms
/// after the key, while two jobs of the open held the main thread: the pool made the next spare page (a web view and a
/// Chromium browser, then its setup calls and first load) in the key's own pass, and the bar's palette actions were read
/// in one 7-10 ms task 95 ms after the key. Neither is something the person sees in that open.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct NewTabOpenFramesTests {
    /// The pane Cmd-T opens in, once the window shows a workspace with a pane.
    static func focusedPane(_ services: AppServices) async throws -> (NSWindow, PaneController) {
        try await PasswordManagerRouteTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
        let controller = try #require(services.windows.active)
        let window = try #require(controller.window)
        window.orderFrontRegardless()
        try await PasswordManagerRouteTests.until({ controller.content?.focusedPane != nil }, report: { "no focused pane" })
        return (window, try #require(controller.content?.focusedPane))
    }

    /// Marks each New Tab page view that the tab store has now as one that the person used, so no tab takes its view
    /// (`AgentTabStore.idlePage`: a New Tab tab that a pane shows takes the view of an untouched New Tab page that the
    /// pane leaves or that no window shows, before the pool's spare and before a cold page). For a test of the pool's
    /// path or of the cold path: its app can start on a New Tab page, and its New Tab key must not get that page's view.
    static func useEachNewTabPage(_ services: AppServices) {
        for view in services.agentTabs.views.values where view.model.newTab != nil { view.model.hostTouch.mark("the test's setup") }
    }

    /// The next spare page is made once the open that took the parked one settled, never in the key's turn or the
    /// frames of its open.
    ///
    /// `used` false, the second form (`NewTabHoldMovesItsPageTests.theIdlePage`): the pool has its page AND the pane
    /// shows a New Tab page that the person did not touch. Want: the key's tab takes that page's view, the pool keeps
    /// its page, and the pool makes no page in the 2 frames after the key.
    @Test(arguments: [true, false]) func cmdTMakesTheNextSpareOnlyAfterItsOpenSettled(used: Bool) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-open-frames-spare")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let (window, pane) = try await Self.focusedPane(services)
            let folder = FileManager.default.temporaryDirectory.appending(path: "open-frames-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let html = folder.appending(path: "index.html")
            try Data("<html><body>New Tab spare fixture</body></html>".utf8).write(to: html)
            let pool = services.newTabSpares
            var made: [AgentPaneView] = []
            defer {
                pool.makeSpare = nil
                pool.dropAll()
                made.forEach { $0.close() }
                try? FileManager.default.removeItem(at: folder)
            }
            // An inert page stands in for WebKit's: the pool's own timing runs.
            pool.dropAll()
            pool.makeSpare = { page in
                let model = AgentPaneModel(host: services.agentTabs.host, newTab: page)
                guard let view = AgentPaneView(model: model, source: .bundled(html)) else { return nil }
                made.append(view)
                return view
            }
            pool.retarget(window)
            pool.prewarm()
            pool.start()
            try await PasswordManagerRouteTests.until({ pool.spare != nil }, report: { "no spare was parked" })
            let spare = try #require(pool.spare?.view)
            let before = made.count

            if !used {
                let idle = try await NewTabHoldMovesItsPageTests.theIdlePage(of: pane, services)
                let openings = pool.openings.count, left = pane.currentTabKey
                NewTabPage.open(in: pane, seed: nil)
                let key = NewTabHoldMovesItsPageTests.afterAKey(in: pane, left: left, services, openings: openings)
                let keptInTheTurn = pool.spare?.view === spare
                await NewTabPageAtItsFrameTests.frame(services)
                await NewTabPageAtItsFrameTests.frame(services)
                print("""
                    NewTabOpenFramesTests: the second form, a filled pool and an idle page at one New Tab key: the new tab took the \
                    idle page view: \(key.took === idle), the pool's page: \(key.took === spare); the open's record says `idle`: \
                    \(key.record.map { String($0.idle) } ?? "no record"), `spare`: \(key.record.map { String($0.spare) } ?? "no record"); \
                    the pool kept its page at the return of the key's call: \(keptInTheTurn), after 2 frames: \(pool.spare?.view === spare); \
                    pages that the pool made in the key's turn and the 2 frames: \(made.count - before)
                    """)
                #expect(key.took === idle, "with a filled pool and an idle page, the new tab did not take the idle page view")
                #expect(key.record?.idle == true && key.record?.spare == false, "the record of an open that took an idle page does not say `idle` and not `spare`")
                #expect(keptInTheTurn && pool.spare?.view === spare, "the pool gave its page away at a key whose tab took an idle page view")
                #expect(made.count == before, "the pool made \(made.count - before) pages at a key whose tab took an idle page view")
                return
            }
            Self.useEachNewTabPage(services) // the pool's path: no idle page that the key's tab takes first
            NewTabPage.open(in: pane, seed: nil)
            #expect(pool.spare?.view !== spare, "Cmd-T did not adopt the parked spare")
            // The open's frames (60 ms: 7 refreshes at 120 Hz, the films' drops came 50-150 ms after the key).
            try await Task.sleep(for: .milliseconds(60))
            #expect(made.count == before, "the next spare was made in the open's frames (\(made.count - before) made within 60 ms)")
            // It still comes soon after, with no input, so the next Cmd-T finds a page loaded or loading.
            try await PasswordManagerRouteTests.until({ made.count == before + 1 }, within: .seconds(3),
                                                      report: { "no next spare after the open settled" })
        }
    }

    /// The bar's palette actions are read in slices on the main thread's budgeted work, never every action in one task:
    /// the bench spans (`newTab.paletteActions`, one per main-thread task that reads actions) show several short tasks.
    ///
    /// The row waits by frames, with no clock: it is the display to the hand-over of its own ask
    /// (`NewTabCommandListKeptTests.listed`), which joins the listing that the key's page asked for. The spans are
    /// those from the key to that hand-over: the rest of one listing, or one whole listing.
    ///
    /// The list is that of the view of the key's own page, and the key opens exactly one page. The page of the next
    /// workspace is no page of the key: the app makes it ahead of its key in idle frames, with a view and a fill of
    /// its own, so its list would hide a page of the key that has none.
    @Test func cmdTListsTheBarsPaletteActionsInSlices() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-open-frames-actions")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let (_, pane) = try await Self.focusedPane(services)
            let pool = services.newTabSpares
            pool.dropAll()
            pool.makeSpare = { _ in nil }
            defer { pool.makeSpare = nil }
            // The read after the asks knows a page of before by its tab: by the store's id of it. This wait is the fixture's.
            try await NewTabCommandListKeptTests.settle(services)
            let tabs = services.agentTabs, known = Set(tabs.newTabPages.keys)
            let lister = services.newTabActions, before = lister.counts
            let inAir = services.mainWork.frames.activeClients.contains(NewTabCommandListKeptTests.lister)
            BenchSpans.begin()
            NewTabPage.open(in: pane, seed: nil)
            // The lines of the 2 asks' tasks have the fixed work: they print after the row read its values.
            let first = await NewTabCommandListKeptTests.listed(services, prints: false)
            let reads = BenchSpans.end().filter { $0.name == "newTab.paletteActions" }
            let handed = lister.counts
            // A page whose view is made after the first hand-over has the list at the second ask's.
            let second = await NewTabCommandListKeptTests.listed(services, prints: false)
            // The pages by their keys of now: a page's key is its tab's, a provisional one until the store answers. The
            // list is the view's: the page that the app stores for a tab never has one.
            let pages = NewTabCommandListKeptTests.opened(services, after: known)
            let view = pages.count == 1 ? tabs.views[pages[0]] : nil
            let has = view?.model.newTab?.omnibar.actions.count ?? 0
            print("new-tab-open-frames: Cmd-T's list: \(first.frames) frames with a lister task from the key to the first hand-over, \(reads.count) "
                + "tasks that read actions in them, \(handed.started - before.started) listings started and \(handed.actionsRead - before.actionsRead) "
                + "catalog actions read to their end; the lister \(inAir ? "had" : "had no") task at the key; \(second.frames) frames with a "
                + "lister task for a second ask; the key opened \(pages.count) New Tab pages; the view of its page has \(has) actions")
            first.tasks.printLine()
            second.tasks.printLine()
            // Exactly one new page, then its view: a second new page with a view would hide a page of the key that has none.
            try #require(pages.count == 1,
                         "the key opened \(pages.count) New Tab pages where 1 is wanted: \(NewTabCommandListKeptTests.named(pages, services, pane))")
            try #require(view != nil, "the key's page has no view after its 2 asks: \(NewTabCommandListKeptTests.named(pages, services, pane))")
            #expect(first.list != nil && second.list != nil && has > 0,
                    "the view of the key's page did not get the palette's actions: \(has) actions after \(first.frames) + \(second.frames) frames with a lister task")
            // A listing takes one task to start and one to arrange; the reads between them are the slices.
            #expect(reads.count >= 4, "every palette action was read in one main-thread task (\(reads.map(\.milliseconds)) ms)")
        }
    }

    /// A page that joins the New Tab pages after the fill was asked for (Cmd-N's first page, `firstPage(cwd:token:)`)
    /// gets the palette's actions too. Cmd-N gives the page its view in the key's turn, with no second ask for the
    /// list, and the row does the same: the view takes the list. A page with no view takes none (the page that the app
    /// stores for it never has a list), so the row waits for the view's list, not for the stored page's.
    ///
    /// The row waits by frames, with no clock: it is the display to the hand-over of its own ask
    /// (`NewTabCommandListKeptTests.listed`). `firstPage(cwd:token:)` asked for the fill before the page had its
    /// view; the row's ask joins that fill's first task or its listing, and each waiter gets the list in the turn of
    /// one hand-over. So the view has its list when the row's ask has its own.
    @Test func cmdNsFirstPageGetsThePalettesActions() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-open-frames-cmdn")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            _ = try await Self.focusedPane(services)
            let tabs = services.agentTabs, lister = services.newTabActions
            let before = lister.counts
            let made = try #require(tabs.firstPage(cwd: nil, token: nil), "no first page")
            let key = AgentTabKey(machine: "", key: "open-frames-cmdn-\(UUID().uuidString.prefix(8))")
            tabs.newTabPages[key] = made
            let view = try #require(tabs.makeSpare(made.page), "the app made no page view")
            tabs.views[key] = view
            defer {
                view.close()
                tabs.views[key] = nil
                tabs.newTabPages[key] = nil
            }
            let atItsMake = view.model.newTab?.omnibar.actions.count ?? 0
            let asked = await NewTabCommandListKeptTests.listed(services)
            let end = lister.counts, has = view.model.newTab?.omnibar.actions.count ?? 0
            print("new-tab-open-frames: Cmd-N's first page: its view has \(atItsMake) actions at its make and \(has) after \(asked.frames) frames "
                + "with a lister task of the row's ask; \(end.started - before.started) listings started and "
                + "\(end.actionsRead - before.actionsRead) catalog actions read to their end since before the page's make")
            #expect(asked.list != nil && has > 0,
                    "the view of Cmd-N's first page has \(has) actions at the hand-over of the row's ask, after \(asked.frames) frames with a lister task")
            #expect(tabs.newTabPages[key]?.page.omnibar.actions.isEmpty == true, "the stored page of Cmd-N's first page took a list")
        }
    }
}
