import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextBrowserCore
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextFavicons
@testable import CmuxNextSettings
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// The rows of the suite for a page that is open or whose view comes late, and for the icons of the listed rows:
/// a change outside a page's first rows sends that page no event; the native page setting gets the whole lists; a
/// page whose view is made after a change lists the changed row; a kept row has no icon,
/// so an icon address and an icon that arrives map no workspace, and a listed row gets the icon that the walk
/// gives it.
extension NewTabKeySessionWalkTests {
    /// The scripts that a page view sends to its page. A test gives the view its `append` as the view's own
    /// `evaluateScript` value, so each places event of that page is counted here.
    @MainActor private final class Sent {
        var scripts: [String] = []

        /// The places events since the last call, then none: the events whose detail has the two lists and no other
        /// part (the palette's actions go to a page in an event of the same name, with a third part).
        func takePlacesEvents() -> Int {
            let prefix = "window.dispatchEvent(new CustomEvent('acpmux-newtab-places', {detail: "
            var count = 0
            for script in scripts where script.hasPrefix(prefix) {
                let json = script.dropFirst(prefix.count).dropLast("}))".count)
                let detail = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
                if let detail, Set(detail.keys) == ["tabs", "workspaces"] { count += 1 }
            }
            scripts = []
            return count
        }
    }

    /// A change of a tab outside the first rows of the bar sends no places event to an open New Tab page:
    /// the page lists the first 40 rows of each list, and they did not change. A change inside
    /// them sends one event, which is also the sign that the count counts.
    ///
    /// The count is the page view's own `evaluateScript` value, which this test sets. The sign that the feed ran is
    /// a condition of the setup: the kept rows have the changed title.
    ///
    /// This row has no red first by a run. Before the change the page got each row of the session, so each change
    /// of a row sent an event.
    @Test func aChangeOutsideTheFirstRowsSendsNoPlacesEventToAnOpenPage() async throws {
        try await Self.withPane { start in
            let tabs = start.services.agentTabs
            let opened = Self.newTab(start)
            try #require(opened.ran && opened.made == 1,
                         "setup: the New Tab key \(opened.ran ? "ran" : "was refused") and the strip has \(opened.made) new tabs")
            // The frame that shows the key's tab makes its page view.
            await Self.frame(start.services)
            await LargeSessionWindowFixture.drainMain()
            await LargeSessionWindowFixture.drainMain()
            let views = tabs.newTabPages.entries.compactMap { tabs.views[$0.key] }
            try #require(views.count == 1, "setup: \(views.count) New Tab pages have a view, want 1")
            let page = views[0]
            let cap = AgentPaneOmnibar.maximumEntries
            let listed = page.model.newTab?.omnibar.tabs ?? []
            try #require(listed.count == cap, "setup: the page lists \(listed.count) tab rows, want the limit of \(cap)")
            let sent = Sent()
            page.evaluateScript = { sent.scripts.append($0) }

            let terminals = SessionFixtureSize.real.places { $0.isTerminal }
            let near = try #require(terminals.first, "setup: the session has no terminal")
            let far = try #require(terminals.first(where: { $0.workspace > start.workspaces / 2 }),
                                   "setup: the session has no terminal in its second half")
            let store = start.services.machines.local.store

            // Outside the first rows: a terminal of a workspace in the second half of the session.
            let farSurface = LargeSessionWindowFixture.surface(workspace: far.workspace, index: far.index)
            store.apply(LargeSessionWindowFixture.titleChanged(farSurface, raw: "far row", text: "far row", activity: nil))
            await LargeSessionWindowFixture.drainMain()
            await LargeSessionWindowFixture.drainMain()
            let keptFar = (start.services.newTabPlaces.rows ?? []).contains(where: { rows in rows.tabs.contains(where: { $0.title == "far row" }) })
            let afterFar = page.model.newTab?.omnibar.tabs ?? []
            let farEvents = sent.takePlacesEvents()
            try #require(keptFar, "setup: the kept rows do not have the changed title after the drain, so the feed did not run")
            #expect(farEvents == 0, "a change outside the first \(cap) rows sent \(farEvents) places events to the open page, want 0")
            #expect(afterFar == listed, "a change outside the first \(cap) rows changed the page's tab rows")

            // Inside the first rows: the first terminal of the session.
            let nearSurface = LargeSessionWindowFixture.surface(workspace: near.workspace, index: near.index)
            store.apply(LargeSessionWindowFixture.titleChanged(nearSurface, raw: "near row", text: "near row", activity: nil))
            await LargeSessionWindowFixture.drainMain()
            await LargeSessionWindowFixture.drainMain()
            let afterNear = page.model.newTab?.omnibar.tabs ?? []
            let nearEvents = sent.takePlacesEvents()
            print("new tab key, \(start.workspaces) workspaces, 1 open New Tab page with \(listed.count) tab rows: a title change in "
                + "workspace \(far.workspace) sent \(farEvents) places events; a title change in workspace \(near.workspace) sent "
                + "\(nearEvents) places events")
            #expect(nearEvents == 1, "a change inside the first \(cap) rows sent \(nearEvents) places events to the open page, want 1")
            #expect(afterNear.contains(where: { $0.title == "near row" }), "the page's tab rows do not have the row that changed inside them")
        }
    }

    /// With the native New Tab page setting, a page gets the whole lists of the walk, not the first rows:
    /// the native page ranks every row itself, so its input stays what it was before the rows were kept.
    /// For this setting the session's size stays in each page's lists.
    ///
    /// This row is a pin: the lists were the walk's whole lists before the change also.
    @Test func withTheNativePageSettingAPageGetsTheWholeListsOfTheWalk() async throws {
        try await Self.withPane(native: true) { start in
            let cap = AgentPaneOmnibar.maximumEntries
            let walk = Self.walkBeforeTheKeptRows(start.services)
            try #require(walk.tabs.count > cap && walk.workspaces.count > cap,
                         "setup: the walk's lists are \(Self.text(walk.tabs, walk.workspaces)): no list is over the limit of \(cap)")
            let page = NewTabPage.places(start.services, excluding: nil)
            print("new tab key, \(start.workspaces) workspaces, the native page setting: a page gets \(Self.text(page.tabs, page.workspaces)); "
                + "the walk has \(Self.text(walk.tabs, walk.workspaces))")
            #expect(page.tabs == walk.tabs && page.workspaces == walk.workspaces,
                    "with the native page setting a page's lists are not the walk's whole lists")
            #expect(page.folders == walk.folders, "with the native page setting a page's folders are not the walk's folders")
        }
    }

    /// True when one kept tab row has `title`.
    private static func keeps(_ title: String, _ services: AppServices) -> Bool {
        (services.newTabPlaces.rows ?? []).contains(where: { rows in rows.tabs.contains(where: { $0.title == title }) })
    }

    /// A New Tab page whose view is made after a change of a row shows the changed row.
    ///
    /// A page's lists come from the kept rows, and the kept rows get a change some turns after it. A places event
    /// goes only to a page that has a view. So a page that opens in the turn of a change, and whose view is made
    /// after the kept rows got that change, must get the change another way: else it shows the row of before until
    /// the next change of a listed row.
    ///
    /// The steps are the test's own, with no wait for a time. One turn of the main actor has a title change of a
    /// tab in the first rows and 2 New Tab keys, with no prewarmed page. No frame comes between the keys, so the
    /// first key's tab is never the shown one and gets no view. Then the kept rows get the change (a condition of
    /// the setup, as is `the first key's tab has no view`). Then the test selects the first key's tab, so its view
    /// is made at the next frame (if a frame makes none, the test asks the tab store for it, and the print says
    /// so). The second key's page is the shown one: its view is made at a frame after the keys, before or after
    /// the kept rows got the change; it must show the changed row in both orders.
    ///
    /// Before the select the row counts the shown New Tab page as used (`NewTabOpenFramesTests.useEachNewTabPage`):
    /// a tab that the pane shows next takes the view of an untouched New Tab page that the pane leaves
    /// (`AgentTabStore.idlePage`), and then no view is made after the change. That the view is a new one is a
    /// condition of the setup.
    ///
    /// Before the rows were kept, a page's lists came from a walk of the session in the key's call, so the
    /// page of a key after a change had the change (by a read; this file does not compile there).
    ///
    /// `used` false, the second form (`NewTabHoldMovesItsPageTests+IdleStart.swift`): the shown page stays untouched,
    /// so the first key's tab takes that page's view at its select and no view is made. That it took that view is a
    /// condition of the setup. No page loads here, and the row sets no handshake mark: a tab takes an untouched page
    /// view with or without it. Want: the view that the tab took lists the changed row.
    @Test(arguments: [true, false]) func aPageWhoseViewIsMadeAfterAChangeShowsTheChangedRow(used: Bool) async throws {
        try await Self.withPane { start in
            let services = start.services
            let tabs = services.agentTabs
            // No prewarmed page: a tab gets its page view only at a frame that shows it.
            let pool = services.newTabSpares
            pool.dropAll()
            pool.makeSpare = { _ in nil }
            defer { pool.makeSpare = nil }
            let terminals = SessionFixtureSize.real.places { $0.isTerminal }
            let place = try #require(terminals.first, "setup: the session has no terminal")
            let surface = LargeSessionWindowFixture.surface(workspace: place.workspace, index: place.index)
            let store = services.machines.local.store
            let before = Set(tabs.newTabPages.keys.map(\.key))

            // One turn of the main actor: the change, then 2 New Tab keys.
            store.apply(LargeSessionWindowFixture.titleChanged(surface, raw: "late row", text: "late row", activity: nil))
            let firstKey = Self.newTab(start)
            let afterFirst = tabs.newTabPages.entries.filter { !before.contains($0.key.key) }
            let secondKey = Self.newTab(start)
            let keptInTurn = Self.keeps("late row", services)
            try #require(firstKey.ran && firstKey.made == 1 && secondKey.ran && secondKey.made == 1 && afterFirst.count == 1,
                         "setup: the 2 New Tab keys added \(firstKey.made) and \(secondKey.made) tabs; the first opened \(afterFirst.count) pages")
            let first = afterFirst[0].key
            let valueInTurn = (tabs.newTabPages[first]?.page.omnibar.tabs ?? []).contains(where: { $0.title == "late row" })

            // The kept rows get the change, and a frame after the keys shows the second key's tab.
            await LargeSessionWindowFixture.drainMain()
            await LargeSessionWindowFixture.drainMain()
            try #require(Self.keeps("late row", services),
                         "setup: the kept rows do not have the changed title after the drain, so the feed did not run")
            await Self.frame(services)
            await LargeSessionWindowFixture.drainMain()
            try #require(tabs.views[first] == nil,
                         "setup: the first key's tab has a page view before a frame showed it: its view is not made after the change")
            let others = tabs.newTabPages.entries.filter { !before.contains($0.key.key) && $0.key.key != first.key }
            let shownRows = others.compactMap { tabs.views[$0.key] }.first?.model.newTab?.omnibar.tabs
            let shownHas = shownRows?.contains(where: { $0.title == "late row" })

            // The test's own step: the first key's tab is selected, so its page view is made now. The shown page counts
            // as used first: else the first key's tab takes that page's view (`AgentTabStore.idlePage`), and no view is made.
            let id = try #require(start.pane.orderedIDs.first(where: { $0.rawValue == first.key }),
                                  "setup: the strip does not list the first key's tab")
            if !used {
                let shown = try #require(start.pane.currentTabKey.flatMap { tabs.existingView($0) }, "setup: the tab that the pane shows has no page view before the select")
                try #require(shown.isUntouchedNewTab, "setup: the page that the pane shows is no untouched New Tab page before the select")
                start.pane.select(id)
                await Self.frame(services)
                let took = tabs.views[first]
                let rows = took?.model.newTab?.omnibar.tabs ?? []
                let has = rows.contains(where: { $0.title == "late row" })
                print("new tab key, \(start.workspaces) workspaces, a title change and 2 New Tab keys in one turn, the second form: the first key's tab "
                    + "has a page view one frame after its select: \(took != nil), the view of the tab that the pane left: \(took === shown); "
                    + "it lists \(rows.count) tab rows and the change: \(has); the shown page listed the change before the select: \(shownHas.map { "\($0)" } ?? "it had no view")")
                try #require(took === shown, "setup: the first key's tab did not take the page view of the tab that the pane left, so this form says nothing")
                #expect(has, "the page view that a tab took after the change lists the tab's title of before the change")
                return
            }
            NewTabOpenFramesTests.useEachNewTabPage(services)
            let viewsBefore = tabs.views.values.map { $0 }
            start.pane.select(id)
            await Self.frame(services)
            let byFrame = tabs.views[first]
            let made = byFrame ?? tabs.view(for: first.key, machine: first.machine)
            let view = try #require(made, "setup: the first key's tab gets no page view after its select")
            try #require(!viewsBefore.contains { $0 === view }, "setup: the view of the first key's tab was there before its select, so it was not made after the change")
            let rows = view.model.newTab?.omnibar.tabs ?? []
            let has = rows.contains(where: { $0.title == "late row" })
            let shownText = shownHas.map { "\($0)" } ?? "it has no view"
            print("new tab key, \(start.workspaces) workspaces, a title change and 2 New Tab keys in one turn: the kept rows had the change "
                + "in that turn: \(keptInTurn); the first key's page value had it in that turn: \(valueInTurn). After the kept rows got it: "
                + "the second key's page (the shown one) lists it: \(shownText); the first key's page, "
                + "whose view came after its select (by a frame: \(byFrame != nil)), lists \(rows.count) tab rows and the change: \(has)")
            #expect(has, "the page whose view was made after the change lists the tab's title of before the change")
            #expect(shownHas == true, "the shown page does not list the changed title after the kept rows got it (\(shownText))")
        }
    }

    /// The second form of the key's part of `aChangeWithThreeOpenPagesMapsOneWorkspaceAtMostAfterIt`
    /// (`NewTabHoldMovesItsPageTests+IdleStart.swift`): the pane shows an untouched New Tab page, so the key's tab
    /// takes that page's view. That it took that view is a condition of the setup. No page loads here, and the row
    /// sets no handshake mark. Want: after the key's call the main actor maps one workspace at most.
    ///
    /// The title change's part of that row has the first form only: it has no New Tab key.
    @Test func aNewTabKeyThatTakesAnIdlePageViewMapsOneWorkspaceAtMostAfterIt() async throws {
        try await Self.withPane { start in
            let tabs = start.services.agentTabs
            let opened = Self.newTab(start)
            try #require(opened.ran && opened.made == 1, "setup: the setup's New Tab key \(opened.ran ? "ran" : "was refused") and the strip has \(opened.made) new tabs")
            await Self.frame(start.services)
            await LargeSessionWindowFixture.drainMain()
            let left = start.pane.currentTabKey
            let idle = try #require(left.flatMap { tabs.existingView($0) }, "setup: the tab of the setup's New Tab key has no page view after its frame")
            try #require(idle.isUntouchedNewTab, "setup: the page view of the setup's New Tab key is no untouched New Tab page")

            _ = start.visits.takeByWorkspace()
            let key = Self.newTab(start)
            try #require(key.ran && key.made == 1, "setup: the New Tab key \(key.ran ? "ran" : "was refused") and the strip has \(key.made) new tabs")
            let inCall = start.visits.takeByWorkspace()
            await LargeSessionWindowFixture.drainMain()
            let afterKey = start.visits.takeByWorkspace()
            let keyMaps = afterKey.values.reduce(0, +)
            await Self.frame(start.services)
            let took = start.pane.currentTabKey.flatMap { $0 == left ? nil : tabs.existingView($0) }
            print("new tab key, \(start.workspaces) workspaces, the second form (the key's tab takes the page view of the tab that the pane left: "
                + "\(took === idle)): the key's call mapped \(inCall.count) different workspaces; after the call the main actor mapped "
                + "\(afterKey.count) different workspaces in \(keyMaps) maps")
            try #require(took === idle, "setup: the key's tab did not take the page view of the tab that the pane left, so this row says nothing")
            #expect(afterKey.count <= 1,
                    "after a New Tab key whose tab took an idle page view the main actor mapped \(afterKey.count) workspaces in \(keyMaps) maps, want its own at most")
        }
    }

    /// A New Tab page whose view is a prewarmed page, taken after a change of a row, shows the changed row.
    ///
    /// The steps are those of `aPageWhoseViewIsMadeAfterAChangeShowsTheChangedRow`, with one more. The keys get no
    /// prewarmed page. After the kept rows got the change, the tab store has one prewarmed page to hand out: the
    /// test's own, made by the store's maker, given to the first tab that asks. Then the test selects the first key's
    /// tab, so its view is that prewarmed page, which takes the tab's page value of the key's turn. That the view is
    /// the prewarmed page is a condition of the setup. Before the select the row counts the shown New Tab page as
    /// used (`NewTabOpenFramesTests.useEachNewTabPage`): a tab that the pane shows next takes the view of an untouched
    /// New Tab page that the pane leaves before a prewarmed page (`AgentTabStore.idlePage`).
    @Test func aPageWhoseViewIsAPrewarmedPageTakenAfterAChangeShowsTheChangedRow() async throws {
        try await Self.withPane { start in
            let services = start.services
            let tabs = services.agentTabs
            // No prewarmed page at the keys: a tab gets its page view only at a frame that shows it.
            let pool = services.newTabSpares
            pool.dropAll()
            pool.makeSpare = { _ in nil }
            let poolTake = tabs.takeSpare
            defer {
                pool.makeSpare = nil
                tabs.takeSpare = poolTake
            }
            let terminals = SessionFixtureSize.real.places { $0.isTerminal }
            let place = try #require(terminals.first, "setup: the session has no terminal")
            let surface = LargeSessionWindowFixture.surface(workspace: place.workspace, index: place.index)
            let store = services.machines.local.store
            let before = Set(tabs.newTabPages.keys.map(\.key))

            // One turn of the main actor: the change, then 2 New Tab keys.
            store.apply(LargeSessionWindowFixture.titleChanged(surface, raw: "spare row", text: "spare row", activity: nil))
            let firstKey = Self.newTab(start)
            let afterFirst = tabs.newTabPages.entries.filter { !before.contains($0.key.key) }
            let secondKey = Self.newTab(start)
            try #require(firstKey.ran && firstKey.made == 1 && secondKey.ran && secondKey.made == 1 && afterFirst.count == 1,
                         "setup: the 2 New Tab keys added \(firstKey.made) and \(secondKey.made) tabs; the first opened \(afterFirst.count) pages")
            let first = afterFirst[0].key
            let valueInTurn = (tabs.newTabPages[first]?.page.omnibar.tabs ?? []).contains(where: { $0.title == "spare row" })
            try #require(!valueInTurn,
                         "setup: the first key's page value has the change in the key's turn, so no page value here is of before the change")

            // The kept rows get the change, and a frame after the keys shows the second key's tab.
            await LargeSessionWindowFixture.drainMain()
            await LargeSessionWindowFixture.drainMain()
            try #require(Self.keeps("spare row", services),
                         "setup: the kept rows do not have the changed title after the drain, so the feed did not run")
            await Self.frame(services)
            await LargeSessionWindowFixture.drainMain()
            try #require(tabs.views[first] == nil,
                         "setup: the first key's tab has a page view before a frame showed it: its view is not made after the change")

            // The test's own steps: one prewarmed page for the tab store to hand out, then the first key's tab is selected.
            let spare = try #require(tabs.makeSpare(AgentPaneNewTab(kind: .agent)), "setup: the tab store made no prewarmed page")
            tabs.takeSpare = { _ in tabs.views.entries.contains(where: { $0.value === spare }) ? nil : spare }
            let id = try #require(start.pane.orderedIDs.first(where: { $0.rawValue == first.key }),
                                  "setup: the strip does not list the first key's tab")
            // The shown page counts as used: else the first key's tab takes that page's view before the prewarmed page (`AgentTabStore.idlePage`).
            NewTabOpenFramesTests.useEachNewTabPage(services)
            start.pane.select(id)
            await Self.frame(services)
            let byFrame = tabs.views[first]
            let made = byFrame ?? tabs.view(for: first.key, machine: first.machine)
            let view = try #require(made, "setup: the first key's tab gets no page view after its select")
            try #require(view === spare, "setup: the view of the first key's tab is not the prewarmed page, so this row says nothing")
            let rows = view.model.newTab?.omnibar.tabs ?? []
            let has = rows.contains(where: { $0.title == "spare row" })
            print("new tab key, \(start.workspaces) workspaces, a title change and 2 New Tab keys in one turn, then one prewarmed page: "
                + "the first key's page value had the change in that turn: \(valueInTurn); its view is the prewarmed page "
                + "(by a frame: \(byFrame != nil)), which lists \(rows.count) tab rows and the change: \(has)")
            #expect(has, "the page whose view is a prewarmed page taken after the change lists the tab's title of before the change")
        }
    }

    /// A listed row has the icon that the walk before the kept rows gave it (the icon is
    /// read when a page lists the row), and the read maps no workspace. 3 browser tabs of the first rows get the
    /// address of an icon that the app's icon loader has from the test; the first read of a page's lists asks the
    /// app's icon store for it. The sign that the icon is there is a condition of the setup: the store gives it at
    /// a read (it gives an icon that the loader has with no load of its own, so the sign is not its own cache).
    ///
    /// This row has no red first: in the first form of the kept rows a kept row had the icon.
    @Test func aListedRowHasTheIconThatTheWalkGivesIt() async throws {
        try await Self.withPane { start in
            let services = start.services
            let cap = AgentPaneOmnibar.maximumEntries
            let first = NewTabPage.places(services, excluding: nil)
            let inFirstRows = Set(first.tabs.filter { $0.kind == .browser }.map(\.id))
            let all = services.machines.local.store.workspaces.flatMap { $0.screens.flatMap(\.panes).flatMap(\.tabs) }
            let pages = Array(all.filter { inFirstRows.contains($0.id) }.prefix(3))
            try #require(pages.count == 3, "setup: \(pages.count) browser tabs are in a page's first \(cap) tab rows, want 3")
            let profile = services.browserProfiles.engineProfile(forTab: pages[0].id)
            let address = try #require(URL(string: "https://new-tab-key-walk.invalid/row.png"))
            let image = try Self.png()
            let took = BrowserFaviconLoader.shared.store(image, at: address, profile: profile) != nil
            try #require(took, "setup: the app's icon loader did not take the test's image")
            for tab in pages { tab.faviconURL = address.absoluteString }
            // The first read asks the store for the icon; after the drain the store gives it at a read.
            _ = NewTabPage.places(services, excluding: nil)
            await LargeSessionWindowFixture.drainMain()
            await LargeSessionWindowFixture.drainMain()
            let arrived = services.favicons.image(for: address.absoluteString, profile: profile) != nil
            try #require(arrived, "setup: the app's icon store does not give the icon at a read after the drain")
            _ = start.visits.take()
            let page = NewTabPage.places(services, excluding: nil)
            let atRead = start.visits.take()
            let walk = Self.walkBeforeTheKeptRows(services)
            let withIcon = page.tabs.filter { $0.icon != nil }.map(\.id)
            print("new tab key, \(start.workspaces) workspaces: a page lists \(page.tabs.count) tab rows, \(withIcon.count) with an icon; "
                + "the read mapped \(atRead.workspaces) workspaces")
            #expect(Set(withIcon) == Set(pages.map(\.id)), "the listed rows with an icon are not the 3 tabs that have one")
            #expect(page.tabs == Array(walk.tabs.prefix(cap)), "a page's tab rows, icons included, are not the walk's first \(cap)")
            #expect(atRead.workspaces == 0, "the read of a page's lists mapped \(atRead.workspaces) workspaces, want 0")
        }
    }

    /// A small PNG, as a site's icon.
    private static func png() throws -> Data {
        let made = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        let bitmap = try #require(made, "setup: no bitmap")
        for x in 0..<8 {
            for y in 0..<8 { bitmap.setColor(NSColor(srgbRed: 0.2, green: 0.6, blue: 0.7, alpha: 1), atX: x, y: y) }
        }
        return try #require(bitmap.representation(using: .png, properties: [:]), "setup: the bitmap gives no PNG")
    }

    /// The icons of the session's pages are no part of the kept rows: the map of a workspace
    /// reads no icon and no icon address. So an icon address that 20 tabs get maps no workspace, and an icon that
    /// arrives in the app's icon store maps none.
    ///
    /// The count is the one of this suite: the maps of a workspace for the bar (`newTabPlaceSource`), on the app's
    /// own services, its own places feed and its own icon store, with no New Tab page open. No fetch leaves the
    /// Mac: the test gives the app's icon loader the image of each address, and the loader answers from what it
    /// has. 20 browser tabs of 20 workspaces get the first address, as 20 pages of one site do. Then the test asks
    /// the app's icon store for the second address, which no tab has, as a tab strip asks for an icon, and gives
    /// the loader its image in the same turn: the store's load, which runs in the drain, is the arrival (the store
    /// gives an icon that the loader has already with no load and no arrival). The sign that this icon arrived is
    /// a condition of the setup.
    ///
    /// A report and no condition: if the app's icon store has the first address's icon while no New Tab page is
    /// open. The store does not say who asked for an icon, and the sidebar's rows ask the same store.
    @Test func anIconAddressAndAnIconThatArrivesMapNoWorkspace() async throws {
        try await Self.withPane { start in
            let services = start.services
            let open = services.agentTabs.newTabPages.entries.count
            try #require(open == 0, "setup: \(open) New Tab pages are open")
            let count = 20
            let withAPage = services.machines.local.store.workspaces.compactMap { workspace in
                workspace.screens.flatMap(\.panes).flatMap(\.tabs).first(where: { $0.kind == .browser })
            }
            let pages = Array(withAPage.prefix(count))
            try #require(pages.count == count, "setup: \(pages.count) workspaces have a browser tab, want \(count)")
            let profile = services.browserProfiles.engineProfile(forTab: pages[0].id)
            let image = try Self.png()
            let listed = try #require(URL(string: "https://new-tab-key-walk.invalid/listed.png"))
            let other = try #require(URL(string: "https://new-tab-key-walk.invalid/other.png"))
            let loader = BrowserFaviconLoader.shared
            let tookListed = loader.store(image, at: listed, profile: profile) != nil
            try #require(tookListed, "setup: the app's icon loader did not take the test's image")

            // 20 tabs of 20 workspaces get the address of one icon.
            _ = start.visits.takeByWorkspace()
            for tab in pages { tab.faviconURL = listed.absoluteString }
            await LargeSessionWindowFixture.drainMain()
            await LargeSessionWindowFixture.drainMain()
            let atAddress = start.visits.takeByWorkspace()
            let addressMaps = atAddress.values.reduce(0, +)
            let storeHasListed = services.favicons.cachedImage(for: listed.absoluteString, profile: profile) != nil

            // ONE icon arrives in the app's icon store: an icon of no tab, which the loader gets after the store's ask.
            let hadOther = services.favicons.image(for: other.absoluteString, profile: profile) != nil
            let tookOther = loader.store(image, at: other, profile: profile) != nil
            try #require(tookOther, "setup: the app's icon loader did not take the test's second image")
            await LargeSessionWindowFixture.drainMain()
            await LargeSessionWindowFixture.drainMain()
            let atArrival = start.visits.takeByWorkspace()
            let arrivalMaps = atArrival.values.reduce(0, +)
            let arrived = services.favicons.cachedImage(for: other.absoluteString, profile: profile) != nil
            print("new tab key, \(start.workspaces) workspaces, no New Tab page open: an icon address that \(count) tabs of \(count) "
                + "workspaces got mapped \(atAddress.count) different workspaces in \(addressMaps) maps (the app's icon store has that "
                + "icon then: \(storeHasListed)); ONE icon of no tab that arrived mapped \(atArrival.count) different workspaces in "
                + "\(arrivalMaps) maps")
            try #require(!hadOther && arrived,
                         "setup: the icon of no tab did not arrive in the drain (in the store before: \(hadOther), after: \(arrived))")
            #expect(atAddress.count == 0,
                    "an icon address that \(count) tabs got mapped \(atAddress.count) workspaces in \(addressMaps) maps, want 0")
            #expect(atArrival.count == 0,
                    "ONE icon that arrived mapped \(atArrival.count) workspaces in \(arrivalMaps) maps, want 0")
        }
    }
}
