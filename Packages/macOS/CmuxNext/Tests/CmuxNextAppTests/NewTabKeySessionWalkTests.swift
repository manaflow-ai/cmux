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

/// Decision of 2026-11-16: a New Tab key does no step of the session's size in its own call. The call of the key maps
/// no workspace and reads no tab of another pane for the page's bar: the page gets the bar's open tabs and workspaces
/// after it shows.
///
/// Before the decision, each New Tab key mapped every workspace of the session and every tab of each (the bar's
/// places, `NewTabPage.places`), made the rows of all of them, and put the whole list in the page that the key opens.
/// The cost of one key grew with the session.
///
/// The count: the services map one workspace for the bar through one value that their `init` takes
/// (`newTabPlaceSource`). This suite passes a value that counts its calls, on a whole window of the `real` session
/// (826 workspaces, 1,600 tabs) with no daemon. The count is read directly after the key's call returns, in the same
/// turn of the main actor: no wait, and no time is a condition.
///
/// The app starts its places feed after its first frame (`NewTabPlacesFeed.wire`), and keeps the rows of each
/// workspace from then on. The fixture's window has no first frame, so the setup starts that feed as the app does,
/// before a test's first key, and it needs the feed's first rows. One test here does not: it holds what a page gets
/// when it opens before the feed gave anything.
///
/// A New Tab tab gets its page view at the frame that shows it. A test that needs the view waits for that frame by an
/// event (a probe in the queue of the app's presentation scheduler), not by turns of the main actor: a frame comes
/// by the display's time, so a count of turns can end before it.
///
/// The prints are a report, not a condition: the time of the walk as it was at the decision's date, the bytes of the
/// two lists as the places event carries them, the whole lists that 10 keys of one turn build, and three counters of
/// the sidebar for one key. Limit of the walk's time: a browser tab of this fixture has no favicon, so the walk here
/// makes no PNG; the product's walk makes one for each browser tab with a favicon. Limit of the sidebar's counters:
/// they are the sidebar's own, for the whole test process, so a suite that runs at the same time can add to them.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)))
struct NewTabKeySessionWalkTests {
    /// Counts the workspaces that the services map for a New Tab page's bar. The suite passes `source` to their `init`.
    @MainActor final class Visits {
        /// The tabs of the key's pane: a tab of this set is not a tab of another pane.
        var own: Set<String> = []
        private var workspaces = 0
        private var otherTabs = 0
        private var byWorkspace: [String: Int] = [:]

        /// The time of the first map and of the last one since the last `takeSpan()`.
        private var span: (first: ContinuousClock.Instant, last: ContinuousClock.Instant)?

        func source(_ workspace: WorkspaceModel) -> NewTabPlaces.Source {
            let now = ContinuousClock.now
            span = (span?.first ?? now, now)
            let source = NewTabPlaces.Source(workspace)
            workspaces += 1
            otherTabs += source.tabs.filter { !own.contains($0.id) }.count
            byWorkspace[source.id, default: 0] += 1
            return source
        }

        /// The maps of each workspace since the last call, by the workspace's id, then none.
        func takeByWorkspace() -> [String: Int] {
            let counts = byWorkspace
            byWorkspace = [:]
            return counts
        }

        /// The time from the first map to the last one since the last call, in milliseconds, then none.
        func takeSpan() -> Double? {
            guard let taken = span else { return nil }
            span = nil
            let elapsed = taken.last - taken.first
            return Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3
        }

        /// The counts since the last call, then zero.
        func take() -> (workspaces: Int, otherTabs: Int) {
            let counts = (workspaces, otherTabs)
            workspaces = 0
            otherTabs = 0
            return counts
        }
    }

    /// The creations of one test: each waits here, so the daemon's side answers none before `release()`.
    @MainActor final class HeldCreations {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var released = false

        func wait() async {
            if released { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func release() {
            released = true
            for one in waiting { one.resume() }
            waiting = []
        }
    }

    /// The two lists that a places event carries, for their size as JSON.
    nonisolated struct Lists: Codable, Sendable {
        let tabs: [AgentPaneOmnibar.Tab]
        let workspaces: [AgentPaneOmnibar.Workspace]
    }

    /// The pane of a test, its services and the counter that they call.
    struct Start {
        let pane: PaneController
        let services: AppServices
        let visits: Visits
        /// The workspaces of the session.
        let workspaces: Int
    }

    /// Runs `body` on the focused pane of a whole window of the `real` session. The New Tab key makes a New Tab page
    /// there, and the daemon's side of its creation waits until `body` ends. With `feed`, the app's places feed runs
    /// before `body`, as it does after the app's first frame. With `native`, the native New Tab page setting is on.
    static func withPane(feed: Bool = true, native: Bool = false,
                         _ body: @MainActor (Start) async throws -> Void) async throws {
        _ = NSApplication.shared
        let visits = Visits()
        // An inert address for each New Tab page: the pages load nothing.
        let environment = [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"]
        let services = AppServices(environment: AppEnvironment.current([:]), agentPaneEnvironment: environment,
                                   newTabPlaceSource: { visits.source($0) })
        let directory = FileManager.default.temporaryDirectory.appending(path: "new-tab-key-walk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await LargeSessionWindowFixture.withController(.real, services: services) { store, controller in
            let tabs = services.agentTabs
            try #require(tabs.canHostChat, "setup: this build has no New Tab page")
            let pane = try #require(controller.focusedPane, "setup: the window has no focused pane")
            let held = HeldCreations()
            tabs.localHost = AgentSessionRef.host(installID: "new-tab-key-session-walk")
            tabs.holdsTabs = { _ in true }
            tabs.reachable = { _ in true }
            tabs.create = { _, _, _, _, _, _ in
                await held.wait()
                throw CancellationError()
            }
            visits.own = Set(pane.pane.tabs.map(\.id))
            if native {
                // The setting comes on after the window is there: the window's own start is as in each other test.
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appending(path: "cmux.json")
                try Data(#"{"tabs":{"nativeNewTabPage":true}}"#.utf8).write(to: url)
                let settings = SettingsController(writer: TestSettingsWriter(), registry: services.registry, design: DesignSettings(),
                                                  fileURL: url, managedReader: FixedManagedPreferenceReader(ManagedPreferences()),
                                                  managedWatchFiles: [])
                await settings.reload()
                services.settings = settings
                try #require(settings.snapshot.nativeNewTabPage, "setup: the native New Tab page setting is not on")
            }
            // What the window's own start mapped is not the feed's, and not a key's.
            _ = visits.take()
            _ = visits.takeByWorkspace()
            _ = visits.takeSpan()
            if feed {
                // The feed lives as long as the process (the app's rule): each test leaves one feed behind.
                NewTabPlacesFeed.wire(tabs, services: services)
                await LargeSessionWindowFixture.drainMain()
                await LargeSessionWindowFixture.drainMain()
                let first = visits.takeByWorkspace()
                let span = visits.takeSpan()
                let keptCount = services.newTabPlaces.rows?.count ?? -1
                // A report: the cost of the feed's start in this build (Debug, no daemon, no page).
                print("new tab key, \(store.workspaces.count) workspaces: before a key, the places feed mapped \(first.count) different "
                    + "workspaces in \(first.values.reduce(0, +)) maps, \(span.map { String(format: "%.2f", $0) } ?? "no") ms from the first "
                    + "map to the last")
                try #require(keptCount == store.workspaces.count,
                             "setup: the places feed kept the rows of \(keptCount) workspaces, want \(store.workspaces.count)")
                _ = visits.take()
            }
            var failure: (any Error)?
            do {
                try await body(Start(pane: pane, services: services, visits: visits, workspaces: store.workspaces.count))
            } catch { failure = error }
            // Each creation ends before the window closes.
            held.release()
            await LargeSessionWindowFixture.drainMain()
            if let failure { throw failure }
        }
    }

    /// Stands in the presentation scheduler's queue: its show is the event that a frame's drain ran. Its content is
    /// alive, so it spends nothing of the frame's budget, and it has no focus, so the focused pane shows before it.
    @MainActor private final class FrameProbe: PresentablePane {
        var onShow: () -> Void = {}
        var selectedContentIsAlive: Bool { true }
        var isFocusedInWorkspace: Bool { false }
        func showSelected() { onShow() }
        func showWhileWaiting() {}
    }

    /// Returns when the scheduler's next frame showed what waited for it.
    static func frame(_ services: AppServices) async {
        let probe = FrameProbe()
        await withCheckedContinuation { (shown: CheckedContinuation<Void, Never>) in
            probe.onShow = { shown.resume() }
            services.presentation.setNeedsShowSelected(probe)
        }
    }

    /// One New Tab key. `made`: the tabs that the strip lists more than before the key, read in the key's own call.
    static func newTab(_ start: Start) -> (ran: Bool, made: Int) {
        let before = Set(start.pane.orderedIDs.map(\.rawValue))
        let ran = start.services.registry.perform("newTab.default", invocation: ActionInvocation(origin: .user))
        return (ran, start.pane.orderedIDs.map(\.rawValue).filter { !before.contains($0) }.count)
    }

    /// The walk of each New Tab key's call as it was at the decision's date (`NewTabPage.places`), with the app's own
    /// map of a workspace: it adds nothing to the count.
    static func walkAtTheDecision(_ services: AppServices)
        -> (tabs: [AgentPaneOmnibar.Tab], workspaces: [AgentPaneOmnibar.Workspace], folders: [String]) {
        let sources = services.machines.allWorkspaces.map { workspace, _ in NewTabPlaces.Source(workspace) }
        let current = services.windows.active?.state.workspaceID
        return NewTabPlaces(home: NSHomeDirectory()).places(sources, current: current, excluding: nil) {
            AppServices.dataURL(services.tabFavicon($0))
        }
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3
    }

    /// One New Tab key in a session of 826 workspaces: its call maps no workspace and reads no tab of another pane.
    @Test func aNewTabKeyMapsNoWorkspaceAndReadsNoTabOfAnotherPaneInItsCall() async throws {
        try await Self.withPane { start in
            // The report, before the key: the walk as it was, five times, and the size of its two lists.
            var walks: [Double] = []
            var lists = Lists(tabs: [], workspaces: [])
            for _ in 0..<5 {
                let began = ContinuousClock.now
                let places = Self.walkAtTheDecision(start.services)
                walks.append(Self.milliseconds(since: began))
                lists = Lists(tabs: places.tabs, workspaces: places.workspaces)
            }
            let bytes = try JSONEncoder().encode(lists).count
            let sorted = walks.sorted().map { String(format: "%.2f", $0) }.joined(separator: ", ")
            print("new tab key, \(start.workspaces) workspaces: the walk at the decision's date took \(sorted) ms (5 runs, sorted); "
                + "its two lists are \(lists.tabs.count) tab rows and \(lists.workspaces.count) workspace rows, \(bytes) bytes of JSON")

            _ = SidebarPerfCounters.report(reset: true)
            _ = start.visits.take()
            let began = ContinuousClock.now
            let key = Self.newTab(start)
            let keyTime = Self.milliseconds(since: began)
            let counts = start.visits.take()
            try #require(key.ran && key.made == 1, "setup: the New Tab key \(key.ran ? "ran" : "was refused") and the strip has \(key.made) new tabs")
            print("new tab key, \(start.workspaces) workspaces: the key's call took \(String(format: "%.2f", keyTime)) ms, "
                + "mapped \(counts.workspaces) workspaces and read \(counts.otherTabs) tabs of other panes")
            #expect(counts.workspaces == 0,
                    "the New Tab key's call mapped \(counts.workspaces) of the session's \(start.workspaces) workspaces for the page's bar, want 0")
            #expect(counts.otherTabs == 0,
                    "the New Tab key's call read \(counts.otherTabs) tabs of other panes for the page's bar, want 0")

            // The report, after the key: what the main actor had queued for it, and the sidebar's own counters.
            await LargeSessionWindowFixture.drainMain()
            let later = start.visits.take()
            let sidebar = SidebarPerfCounters.report(reset: true)
            print("new tab key, \(start.workspaces) workspaces: after the key's call the main actor mapped \(later.workspaces) more workspaces; "
                + "sidebar rebuilds \(sidebar["rebuilds"] ?? 0), list_reloads \(sidebar["list_reloads"] ?? 0), "
                + "row_views_made \(sidebar["row_views_made"] ?? 0)")
        }
    }

    /// The report of 10 New Tab keys in one turn of the main actor: how many whole lists the app builds for them. No
    /// condition on the count at the decision's date (one list for the page that shows is the aim).
    @Test func tenNewTabKeysOfOneTurnReportTheWholeListsThatTheAppBuilds() async throws {
        try await Self.withPane { start in
            var made = 0
            for _ in 0..<10 { made += Self.newTab(start).made }
            let turn = start.visits.take()
            await LargeSessionWindowFixture.drainMain()
            let later = start.visits.take()
            try #require(made >= 1, "setup: 10 New Tab keys added no tab to the strip")
            print("new tab key, \(start.workspaces) workspaces: 10 keys of one turn added \(made) tabs and mapped \(turn.workspaces) workspaces "
                + "(\(turn.workspaces / max(1, start.workspaces)) whole lists) in the turn, then \(later.workspaces) workspaces "
                + "(\(later.workspaces / max(1, start.workspaces)) whole lists) in what the main actor had queued")
        }
    }

    /// The second cost of the same walk (decision of 2026-11-16): with 3 open New Tab pages and the app's places feed,
    /// a New Tab key and a title change of one tab map one workspace at most after them (the one that changed).
    ///
    /// Before the decision, each change of a workspace's rows started one whole walk of the session for each New Tab
    /// page that has a view. The feed is the app's own (`NewTabPlacesFeed.wire`), which the setup starts.
    ///
    /// The sign that the feed ran is a condition of the setup: after the title change, the tab rows of a page are not
    /// the rows of before. Without the sign, a feed that did not run in the drain reads as `no map`.
    @Test func aChangeWithThreeOpenPagesMapsOneWorkspaceAtMostAfterIt() async throws {
        try await Self.withPane { start in
            let tabs = start.services.agentTabs
            for _ in 0..<3 {
                let opened = Self.newTab(start)
                try #require(opened.ran && opened.made == 1,
                             "setup: a New Tab key \(opened.ran ? "ran" : "was refused") and the strip has \(opened.made) new tabs")
                // The frame that shows the key's tab makes its page view.
                await Self.frame(start.services)
                await LargeSessionWindowFixture.drainMain()
            }
            let withViews = tabs.newTabPages.entries.compactMap { tabs.views[$0.key] }
            try #require(withViews.count == 3, "setup: \(withViews.count) of 3 New Tab pages have a view")

            // One more New Tab key: what the main actor maps after its call.
            _ = start.visits.takeByWorkspace()
            let key = Self.newTab(start)
            try #require(key.ran && key.made == 1,
                         "setup: the New Tab key \(key.ran ? "ran" : "was refused") and the strip has \(key.made) new tabs")
            let inCall = start.visits.takeByWorkspace()
            await LargeSessionWindowFixture.drainMain()
            let afterKey = start.visits.takeByWorkspace()
            let keyMaps = afterKey.values.reduce(0, +)
            print("new tab key, \(start.workspaces) workspaces, 3 open New Tab pages: the key's call mapped \(inCall.count) different workspaces; "
                + "after the call the main actor mapped \(afterKey.count) different workspaces in \(keyMaps) maps")
            #expect(afterKey.count <= 1,
                    "after a New Tab key the main actor mapped \(afterKey.count) workspaces in \(keyMaps) maps, want its own at most")

            // A title change of one terminal of another workspace, with the sign that the feed ran.
            let terminals = SessionFixtureSize.real.places { $0.isTerminal }
            let place = try #require(terminals.first, "setup: the session has no terminal")
            let surface = LargeSessionWindowFixture.surface(workspace: place.workspace, index: place.index)
            let pages = tabs.newTabPages.entries.compactMap { tabs.views[$0.key] }
            let before = pages.map { $0.model.newTab?.omnibar.tabs ?? [] }
            let store = start.services.machines.local.store
            store.apply(LargeSessionWindowFixture.titleChanged(surface, raw: "feed row", text: "feed row", activity: nil))
            await LargeSessionWindowFixture.drainMain()
            let afterTitle = start.visits.takeByWorkspace()
            let titleMaps = afterTitle.values.reduce(0, +)
            let after = pages.map { $0.model.newTab?.omnibar.tabs ?? [] }
            print("new tab key, \(start.workspaces) workspaces, \(pages.count) open New Tab pages: a title change of one tab mapped "
                + "\(afterTitle.count) different workspaces in \(titleMaps) maps; the tab rows of a page changed: \(after != before)")
            try #require(after != before, "setup: no New Tab page got the changed row in the drain, so the feed did not run")
            #expect(afterTitle.count <= 1,
                    "a title change of one tab mapped \(afterTitle.count) workspaces in \(titleMaps) maps, want the tab's own at most")
        }
    }

    /// A New Tab page that opens before the places feed gave anything (the app's time before its first frame; a
    /// restored New Tab tab) gets its open tabs, its other workspaces and its folders in the key's call. This holds
    /// before the decision of 2026-11-16 and after it: a page refresh carries the two lists and never the folders, so
    /// a page that opened with none would keep none.
    @Test func aPageThatOpensBeforeThePlacesFeedGetsItsListsAndItsFolders() async throws {
        try await Self.withPane(feed: false) { start in
            // The fixture's tabs have no folder: one terminal of the session gets one.
            let store = start.services.machines.local.store
            let all = store.workspaces.flatMap { $0.screens.flatMap(\.panes).flatMap(\.tabs) }
            let terminal = try #require(all.first(where: { $0.kind == .pty && !start.visits.own.contains($0.id) }),
                                        "setup: the session has no terminal in another pane")
            let folder = NSHomeDirectory() + "/src/before-the-feed"
            terminal.cwd = folder
            let tabs = start.services.agentTabs
            let before = Set(tabs.newTabPages.keys.map(\.key))
            let key = Self.newTab(start)
            try #require(key.ran && key.made == 1, "setup: the New Tab key \(key.ran ? "ran" : "was refused") and the strip has \(key.made) new tabs")
            let opened = tabs.newTabPages.entries.filter { !before.contains($0.key.key) }
            try #require(opened.count == 1, "setup: the key opened \(opened.count) New Tab pages")
            let bar = opened[0].value.page.omnibar
            print("new tab key, \(start.workspaces) workspaces, no places feed: the page of the key has \(bar.tabs.count) tab rows, "
                + "\(bar.workspaces.count) workspace rows and \(bar.folders.count) folders in the key's call")
            #expect(!bar.tabs.isEmpty, "a page that opened before the places feed has no open tabs in its bar")
            #expect(!bar.workspaces.isEmpty, "a page that opened before the places feed has no other workspaces in its bar")
            #expect(bar.folders == [folder], "a page that opened before the places feed has the folders \(bar.folders), want the one of the session")

            // The app starts its feed, and in the same turn, before the feed's first rows, the page's view is made:
            // that maps no workspace again (decision of 2026-11-17), and the page keeps the lists of its own walk.
            NewTabPlacesFeed.wire(tabs, services: start.services)
            try #require(start.services.newTabPlaces.rows == nil, "setup: the places feed has rows in the turn of its start")
            _ = start.visits.take()
            let view = try #require(tabs.view(for: opened[0].key.key, machine: opened[0].key.machine), "setup: the page of the key gets no view")
            let atView = start.visits.take()
            #expect(atView.workspaces == 0, "the making of a page's view before the places feed mapped \(atView.workspaces) workspaces, want 0")
            #expect(view.model.newTab?.omnibar.tabs == bar.tabs, "the page's view does not list the tab rows of the page's own walk")
        }
    }

    /// One row of the bar as text, for a message.
    static func text(_ tabs: [AgentPaneOmnibar.Tab], _ workspaces: [AgentPaneOmnibar.Workspace]) -> String {
        "\(tabs.count) tab rows (first: \(tabs.first?.title ?? "none")), "
            + "\(workspaces.count) workspace rows (first: \(workspaces.first?.name ?? "none"))"
    }

    /// The lists that a New Tab page gets from the kept rows are the first rows of the whole walk's lists (decision
    /// of 2026-11-16): the same rows in the same order, on the `real` session and on a session made here, where a
    /// workspace with one place, the page's own tab and the shown workspace are all in the first rows. With no limit
    /// (the native page's lists) they are the walk's whole lists, and the folders are the walk's folders.
    ///
    /// This row has no red first: before the change the app kept no rows to compare.
    @Test func theKeptRowsGiveTheSameFirstRowsAsTheWholeWalk() async throws {
        try await Self.withPane { start in
            let services = start.services
            let cap = AgentPaneOmnibar.maximumEntries
            let kept = try #require(services.newTabPlaces.rows, "setup: the places feed kept no rows")
            let walk = Self.walkAtTheDecision(services)
            let current = services.windows.active?.state.workspaceID
            try #require(walk.tabs.count > cap && walk.workspaces.count > cap,
                         "setup: the walk's lists are \(Self.text(walk.tabs, walk.workspaces)): no list is over the limit of \(cap)")
            let cut = NewTabPlaces.listed(kept, current: current, excluding: nil, limit: cap)
            let whole = NewTabPlaces.listed(kept, current: current, excluding: nil)
            let page = NewTabPage.places(services, excluding: nil)
            print("new tab key, \(start.workspaces) workspaces: from the kept rows a page gets \(Self.text(page.tabs, page.workspaces)) "
                + "and \(page.folders.count) folders; the walk has \(Self.text(walk.tabs, walk.workspaces)) and \(walk.folders.count) folders")
            #expect(cut.tabs == Array(walk.tabs.prefix(cap)), "the first \(cap) tab rows from the kept rows are not the walk's first \(cap)")
            #expect(cut.workspaces == Array(walk.workspaces.prefix(cap)),
                    "the first \(cap) workspace rows from the kept rows are not the walk's first \(cap)")
            #expect(whole.tabs == walk.tabs && whole.workspaces == walk.workspaces,
                    "with no limit the lists from the kept rows are not the walk's whole lists")
            #expect(page.tabs == cut.tabs && page.workspaces == cut.workspaces, "a page's lists are not the first \(cap) rows of each list")
            #expect(page.folders == walk.folders, "a page's folders are not the walk's folders")

            // A session made here: 70 workspaces; each fifth one has one place, the others have two. The page's own tab
            // is the first tab of the second workspace, and the window shows the third workspace.
            let places = NewTabPlaces(home: "/Users/you")
            var surface: UInt64 = 900_000
            var sources: [NewTabPlaces.Source] = []
            for number in 1...70 {
                var made: [TabModel] = []
                for index in 0..<(number % 5 == 0 ? 1 : 2) {
                    surface += 1
                    made.append(TabModel(TabSnapshot(surface: SurfaceID(rawValue: surface), title: "build \(number).\(index)",
                                                     cwd: "/Users/you/src/project-\(number)")))
                }
                sources.append(NewTabPlaces.Source(id: "made-\(number)", name: "made \(number)", tabs: made))
            }
            let own = sources[1].tabs[0].id
            let shown = sources[2].id
            let madeWalk = places.places(sources, current: shown, excluding: own)
            let madeKept = sources.map { places.rows($0) }
            let madeCut = NewTabPlaces.listed(madeKept, current: shown, excluding: own, limit: cap)
            let madeWhole = NewTabPlaces.listed(madeKept, current: shown, excluding: own)
            let firstTabs = Array(madeWalk.tabs.prefix(cap))
            let firstWorkspaces = Array(madeWalk.workspaces.prefix(cap))
            // The 3 rules are in the first rows of the walk: without them this part proves less than it says.
            try #require(madeWalk.tabs.count > cap && madeWalk.workspaces.count > cap,
                         "setup: the made session's lists are \(Self.text(madeWalk.tabs, madeWalk.workspaces)): no list is over the limit")
            let other = sources[1].tabs[1].id, shownTab = sources[2].tabs[0].id, single = sources[4]
            try #require(!firstTabs.contains(where: { $0.id == own }) && firstTabs.contains(where: { $0.id == other }),
                         "setup: the page's own tab is in the walk's first rows, or its workspace's other tab is not")
            try #require(!firstWorkspaces.contains(where: { $0.id == shown }) && firstTabs.contains(where: { $0.id == shownTab }),
                         "setup: the shown workspace is in the walk's first workspace rows, or its tabs are not in the tab rows")
            try #require(!firstWorkspaces.contains(where: { $0.id == single.id }) && firstTabs.contains(where: { $0.id == single.tabs[0].id }),
                         "setup: a workspace with one place is in the walk's first workspace rows, or its tab is not in the tab rows")
            #expect(madeCut.tabs == firstTabs, "made session: the first \(cap) tab rows from the kept rows are not the walk's first \(cap)")
            #expect(madeCut.workspaces == firstWorkspaces,
                    "made session: the first \(cap) workspace rows from the kept rows are not the walk's first \(cap)")
            #expect(madeWhole.tabs == madeWalk.tabs && madeWhole.workspaces == madeWalk.workspaces,
                    "made session: with no limit the lists from the kept rows are not the walk's whole lists")
            #expect(NewTabPlaces.folders(madeKept) == madeWalk.folders, "made session: the kept rows' folders are not the walk's folders")
        }
    }

    /// The cost of the kept rows while no New Tab page is open (decision of 2026-11-16): a title change of one tab
    /// maps the tab's own workspace and no other, and no page gets a places event (an event goes only to a New Tab
    /// page that has a view, and there is none).
    ///
    /// The sign that the feed ran is a condition of the setup: the kept rows have the changed title.
    ///
    /// This row has no red first: before the change the feed did not run while no New Tab page was open.
    @Test func aTitleChangeWithNoNewTabPageOpenMapsTheTabsOwnWorkspaceOnly() async throws {
        try await Self.withPane { start in
            let tabs = start.services.agentTabs
            let pagesBefore = tabs.newTabPages.entries.compactMap { tabs.views[$0.key] }.count
            try #require(pagesBefore == 0, "setup: \(pagesBefore) New Tab pages have a view before the change")
            let terminals = SessionFixtureSize.real.places { $0.isTerminal }
            let place = try #require(terminals.first, "setup: the session has no terminal")
            let surface = LargeSessionWindowFixture.surface(workspace: place.workspace, index: place.index)
            _ = start.visits.takeByWorkspace()
            let store = start.services.machines.local.store
            store.apply(LargeSessionWindowFixture.titleChanged(surface, raw: "kept row", text: "kept row", activity: nil))
            await LargeSessionWindowFixture.drainMain()
            await LargeSessionWindowFixture.drainMain()
            let mapped = start.visits.takeByWorkspace()
            let maps = mapped.values.reduce(0, +)
            let kept = start.services.newTabPlaces.rows ?? []
            let pagesAfter = tabs.newTabPages.entries.compactMap { tabs.views[$0.key] }.count
            print("new tab key, \(start.workspaces) workspaces, no New Tab page open: a title change of one tab mapped "
                + "\(mapped.count) different workspaces in \(maps) maps; \(pagesAfter) New Tab pages have a view")
            try #require(kept.contains(where: { rows in rows.tabs.contains(where: { $0.title == "kept row" }) }),
                         "setup: the kept rows do not have the changed title after the drain, so the feed did not run")
            #expect(mapped.count == 1, "a title change of one tab mapped \(mapped.count) workspaces in \(maps) maps, want the tab's own only")
            #expect(pagesAfter == 0, "\(pagesAfter) New Tab pages have a view after the change: a places event can go to them")
        }
    }

    /// The holder of the kept rows, with no app (decision of 2026-11-16): before its first rows a page's lists come
    /// from one walk, and after them from no walk; the text of one icon is made one time for the same icon object.
    /// A read asks for the icon of each listed browser row and of no other row (decision of 2026-11-17).
    ///
    /// This row has no red first: the holder is new with the change.
    @Test func theHolderWalksOnlyBeforeItsFirstRowsAndMakesOneTextForOneIcon() {
        let places = NewTabPlaces(home: "/Users/you")
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 910_001), title: "build", cwd: "/Users/you/src/project"))
        let page = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 910_002), kind: .browser, title: "Docs", url: "https://example.com/docs"))
        let rows = [places.rows(NewTabPlaces.Source(id: "held-1", name: "held 1", tabs: [tab, page]))]
        let kept = NewTabPlacesKept()
        var walks = 0
        var asked: [String] = []
        let before = kept.places(current: nil, excluding: nil, limit: 40, icon: { _ in nil }) {
            walks += 1
            return rows
        }
        kept.keep(rows)
        let after = kept.places(current: nil, excluding: nil, limit: 40, icon: { id in
            asked.append(id)
            return "icon of \(id)"
        }) {
            walks += 1
            return []
        }
        #expect(walks == 1, "the holder walked \(walks) times for 2 reads, want 1: the read before its first rows only")
        #expect(before.tabs.map(\.id) == after.tabs.map(\.id) && before.folders == after.folders && after.tabs.map(\.id) == [tab.id, page.id],
                "the lists from the walk and from the kept rows differ, or do not have the 2 tabs")
        #expect(after.folders == ["/Users/you/src/project"], "the kept folders are \(after.folders)")
        #expect(asked == [page.id], "the read asked for the icons of \(asked), want the one of the browser row only")
        #expect(after.tabs.map(\.icon) == [nil, "icon of \(page.id)"], "the listed rows' icons are \(after.tabs.map(\.icon))")
        #expect((kept.rows ?? []).flatMap(\.tabs).allSatisfy({ $0.icon == nil }), "a kept row has an icon")

        final class Icon {}
        let icon = Icon(), other = Icon()
        var made = 0
        let texts = [icon, icon, other, icon].map { object in
            kept.icon(object) {
                made += 1
                return "text \(made)"
            }
        }
        #expect(made == 2, "the holder made \(made) texts for 2 icon objects, want 2")
        #expect(texts == ["text 1", "text 1", "text 2", "text 1"], "the texts by icon are \(texts)")
    }
}
