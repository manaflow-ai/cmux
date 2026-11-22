import AppKit
@testable import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// The rows of the suite for a New Tab page that has no view: the page of a tab that its pane does not show, and the
/// first page of a new workspace before its pane shows it. The app stores such a page and makes the tab's view from
/// the stored page when the tab shows. A list of actions in a stored page has nothing that says what it was read
/// under: its view shows it after a change of the registry too, and its person's first input reads nothing again.
/// Each row has such a page at a read of the actions for every page, changes a key binding, and then makes the view
/// as a tab's show makes it. The view's list is then the list of now.
extension NewTabCommandListKeptTests {
    /// What a row of this file starts from: an app with one New Tab page that has no view.
    @MainActor private struct Stored {
        let services: AppServices
        let key: AgentTabKey
        /// The keys of the New Tab row in the list that was read while the page had no view.
        let keys: [String]

        /// Makes the page's view as a tab's show makes it: from the stored page with the lists of its make
        /// (`listsAtViewMake`, which asks for the palette's actions), by the app's own maker of a page view. The
        /// view is the tab's from this turn on.
        func show() throws -> AgentPaneView {
            let tabs = services.agentTabs
            let stored = try #require(tabs.newTabPages[key], "the row did not make its case: the app dropped the stored page")
            let page = stored.page.listing(stored.handler.listsAtViewMake(key.key))
            let view = try #require(tabs.makeSpare(page), "the app made no page view")
            tabs.views[key] = view
            return view
        }
    }

    /// The keys that the New Tab row of `actions` shows; none when the list has no such row.
    private static func keys(_ actions: [AgentPaneOmnibar.Action]?) -> [String] {
        actions?.first { $0.id == "newTab.default" }?.keycaps ?? []
    }

    /// The person gives the New Tab key another binding: a change of the registry, and other keys in the New Tab row.
    private static func rebind(_ services: AppServices) {
        services.registry.setShortcutOverride(CmuxNextActions.Shortcut("t", modifiers: [.control]), for: "newTab.default")
    }

    /// Runs `body` in an app (with its own daemon) that has one New Tab page with no view. The page was there at one
    /// read of the actions for every page, as a page's first use asks for it.
    private static func stored(_ install: String, _ body: @MainActor (Stored) async throws -> Void) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: install)
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            _ = try await NewTabOpenFramesTests.focusedPane(services)
            // No page is prepared in the row's frames.
            let spares = services.newTabSpares
            spares.dropAll()
            spares.makeSpare = { _ in nil }
            defer { spares.makeSpare = nil }
            let tabs = services.agentTabs
            let made = try #require(tabs.firstPage(cwd: nil, token: nil), "setup: the app made no New Tab page")
            let key = AgentTabKey(machine: "", key: "list-kept-stored-\(UUID().uuidString.prefix(8))")
            tabs.newTabPages[key] = made
            defer {
                tabs.views[key]?.close()
                tabs.views[key] = nil
                tabs.newTabPages[key] = nil
            }
            // The fixture is the display to the hand-over of the launch's list. Then the actions are read again for
            // every page: the page with no view is one of them.
            _ = await listed(services)
            NewTabPage.fillPaletteActions(services, again: true)
            let read = await listed(services)
            let list = try #require(read.list, "setup: the read for every page never handed its list over")
            try #require(tabs.views[key] == nil, "the row did not make its case: the page has a view before the row makes it")
            let keys = Self.keys(list.actions)
            try #require(!keys.isEmpty, "the row did not make its case: the list of \(list.actions.count) rows has no New Tab row with keys")
            print("new-tab-list: a page with no view at a read for every page: its stored page has "
                + "\(tabs.newTabPages[key]?.page.omnibar.actions.count ?? 0) of the \(list.actions.count) rows; the New Tab row shows the keys \(keys)")
            try await body(Stored(services: services, key: key, keys: keys))
        }
    }

    /// The page had no view at a read of the actions. Then a key binding changes and a list is read under the keys of
    /// now. Then the tab shows: its view takes the list of now with no read, and its person's first input reads the
    /// actions again, since that list was read before the view asked.
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func aViewMadeFromAStoredPageTakesTheKeptListAndReadsAgainAtItsFirstInput() async throws {
        try await Self.stored("cn-list-kept-stored") { stored in
            let services = stored.services, lister = services.newTabActions, frames = services.mainWork.frames
            Self.rebind(services)
            let asked = await Self.listed(services)
            let now = try #require(asked.list, "setup: the ask after the change of the key binding never got a list")
            let keys = Self.keys(now.actions)
            try #require(keys != stored.keys, "the row did not make its case: the New Tab row shows the keys \(keys) before and after the change")
            try #require(lister.kept == now, "the row did not make its case: the list of now is not kept at the view's make")
            let before = lister.counts

            let view = try stored.show()
            // The row is the display to the hand-over of its own ask, which comes after the view's.
            let made = await Self.listed(services)
            let shown = lister.counts
            let has = view.model.newTab?.omnibar.actions
            print("new-tab-list: a view made from a stored page, with a kept list: \(made.frames) frames with a lister task from the view's make to its "
                + "list, \(shown.started - before.started) listings started; its New Tab row shows the keys \(Self.keys(has)) and it has \(has?.count ?? 0) "
                + "rows; the list of now has the keys \(keys) and \(now.actions.count) rows; the list of before the change had the keys \(stored.keys)")
            try #require(services.agentTabs.views[stored.key] === view, "the row did not make its case: the app dropped the row's view")
            #expect(has == now.actions,
                    "the view shows the keys \(Self.keys(has)) in its New Tab row (\(has?.count ?? 0) rows); the list of now has the keys \(keys) (\(now.actions.count) rows)")
            #expect(shown.started == before.started, "the view's make started \(shown.started - before.started) listings while the list of now is kept")

            // The page's own report of its person's first input. The write of the page's flag only asks for the read, in
            // the main queue's next turn; the row is the display from then to the listing's first task.
            try #require(!frames.activeClients.contains(Self.lister), "the row did not make its case: the lister has a task before the first input")
            _ = await view.model.respond(to: .touched)
            await withCheckedContinuation { turn in DispatchQueue.main.async { turn.resume() } }
            let armed = frames.activeClients.contains(Self.lister)
            let limit = Self.frameLimit(services)
            var fired = 0
            while lister.counts.started == shown.started, frames.activeClients.contains(Self.lister), fired < limit {
                services.mainWork.frameDidFire()
                fired += 1
            }
            let end = lister.counts
            print("new-tab-list: the first input in a view made from a stored page: the lister \(armed ? "has" : "has no") task one turn after it; "
                + "\(end.started - shown.started) listings started in \(fired) frames of the row")
            #expect(end.started == shown.started + 1, "the first input in the view started \(end.started - shown.started) listings where 1 is wanted")
            // The listing's end, before the app closes.
            _ = await Self.listed(services)
        }
    }

    /// The same page when no list is kept at its tab's show: the change of the key binding is the last thing before
    /// it. One listing reads the actions under the keys of now, and the view shows that list.
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func aViewMadeFromAStoredPageAfterAChangeOfAKeyBindingShowsTheListOfNow() async throws {
        try await Self.stored("cn-list-kept-stored-cold") { stored in
            let services = stored.services, lister = services.newTabActions
            Self.rebind(services)
            try #require(lister.kept == nil, "the row did not make its case: a list is kept after the change of the key binding")
            let before = lister.counts

            let view = try stored.show()
            // The row is the display to the hand-over of its own ask: it joins the listing that the view's make starts.
            let made = await Self.listed(services)
            let end = lister.counts
            let now = try #require(made.list, "the ask at the view's make never got a list")
            let keys = Self.keys(now.actions), has = view.model.newTab?.omnibar.actions
            print("new-tab-list: a view made from a stored page, with no kept list: \(made.frames) frames with a lister task from the view's make to its "
                + "list, \(end.started - before.started) listings started; its New Tab row shows the keys \(Self.keys(has)) and it has \(has?.count ?? 0) "
                + "rows; the list of now has the keys \(keys) and \(now.actions.count) rows; the list of before the change had the keys \(stored.keys)")
            try #require(keys != stored.keys, "the row did not make its case: the New Tab row shows the keys \(keys) before and after the change")
            try #require(services.agentTabs.views[stored.key] === view, "the row did not make its case: the app dropped the row's view")
            #expect(has == now.actions,
                    "the view shows the keys \(Self.keys(has)) in its New Tab row (\(has?.count ?? 0) rows); the list of now has the keys \(keys) (\(now.actions.count) rows)")
            #expect(end.started == before.started + 1, "the view's make and one ask started \(end.started - before.started) listings where 1 is wanted")
        }
    }

    /// What a page with no view costs at a fill. No list is kept (a key binding changed), each page with a view has a
    /// list, and the app asks for a fill as it does at a page's make. A page with no view that has no list asks for a
    /// listing then: one at most. The next fill, with that listing's list kept, starts none.
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func aFillWhileAPageHasNoViewAndNoListIsKeptStartsAtMostOneListing() async throws {
        try await Self.stored("cn-list-kept-stored-fill") { stored in
            let services = stored.services, lister = services.newTabActions, tabs = services.agentTabs
            Self.rebind(services)
            try #require(lister.kept == nil, "the row did not make its case: a list is kept after the change of the key binding")
            let lacking = tabs.newTabPages.keys.filter { tabs.views[$0]?.model.newTab?.omnibar.actions.isEmpty == true }.count
            try #require(lacking == 0, "the row did not make its case: \(lacking) pages with a view have no list before the fill")
            let unseen = tabs.newTabPages.keys.filter { tabs.views[$0] == nil }
            let bare = unseen.filter { tabs.newTabPages[$0]?.page.omnibar.actions.isEmpty != false }.count
            try #require(!services.mainWork.frames.activeClients.contains(Self.lister), "the row did not make its case: the lister has a task before the fill")
            let before = lister.counts

            NewTabPage.fillPaletteActions(services)
            let first = Self.firstTask(services, after: before)
            let byTheFill = lister.counts.started - before.started
            // The row's own ask joins the fill's listing, or starts one when the fill started none: a list is kept at its end.
            let asked = await Self.listed(services)
            let read = lister.counts
            try #require(asked.list != nil && lister.kept != nil, "the row did not make its case: no list is kept after the listing's end")

            NewTabPage.fillPaletteActions(services)
            let second = Self.firstTask(services, after: read)
            let end = lister.counts
            print("new-tab-list: a fill while a page has no view and no list is kept: \(unseen.count) pages with no view, \(bare) of them with no "
                + "stored list; \(byTheFill) listings started by the fill in \(first) frames of the row; \(read.started - before.started) listings "
                + "and \(read.actionsRead - before.actionsRead) catalog actions read to the hand-over of the row's ask, \(asked.frames) frames with a "
                + "lister task; a second fill, with that list kept: \(end.started - read.started) listings started in \(second) frames of the row")
            #expect(byTheFill <= 1, "one fill started \(byTheFill) listings while \(unseen.count) pages have no view; 1 at most is wanted")
            #expect(end.started == read.started, "a fill started \(end.started - read.started) listings while a list is kept")
        }
    }

    /// Is the display to a fill's first task, which hands the kept list over, starts a listing, or finds that no page
    /// asks: one frame after another while the lister has a task and no listing started since `counts`. Returns the frames.
    private static func firstTask(_ services: AppServices, after counts: AgentPaneNewTabActions.Counts) -> Int {
        let frames = services.mainWork.frames, limit = frameLimit(services)
        var fired = 0
        while services.newTabActions.counts.started == counts.started, frames.activeClients.contains(lister), fired < limit {
            services.mainWork.frameDidFire()
            fired += 1
        }
        return fired
    }
}
