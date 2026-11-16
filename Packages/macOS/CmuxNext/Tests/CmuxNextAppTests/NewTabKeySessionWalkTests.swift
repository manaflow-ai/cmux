import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
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
/// The prints are a report, not a condition: the time of the walk as it was at the decision's date, the bytes of the
/// two lists as the places event carries them, the whole lists that 10 keys of one turn build, and three counters of
/// the sidebar for one key. Limit of the walk's time: a browser tab of this fixture has no favicon, so the walk here
/// makes no PNG; the product's walk makes one for each browser tab with a favicon. Limit of the sidebar's counters:
/// they are the sidebar's own, for the whole test process, so a suite that runs at the same time can add to them.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)))
struct NewTabKeySessionWalkTests {
    /// Counts the workspaces that the services map for a New Tab page's bar. The suite passes `source` to their `init`.
    @MainActor private final class Visits {
        /// The tabs of the key's pane: a tab of this set is not a tab of another pane.
        var own: Set<String> = []
        private var workspaces = 0
        private var otherTabs = 0
        private var byWorkspace: [String: Int] = [:]

        func source(_ workspace: WorkspaceModel) -> NewTabPlaces.Source {
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

        /// The counts since the last call, then zero.
        func take() -> (workspaces: Int, otherTabs: Int) {
            let counts = (workspaces, otherTabs)
            workspaces = 0
            otherTabs = 0
            return counts
        }
    }

    /// The creations of one test: each waits here, so the daemon's side answers none before `release()`.
    @MainActor private final class HeldCreations {
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
    private nonisolated struct Lists: Codable, Sendable {
        let tabs: [AgentPaneOmnibar.Tab]
        let workspaces: [AgentPaneOmnibar.Workspace]
    }

    /// The pane of a test, its services and the counter that they call.
    private struct Start {
        let pane: PaneController
        let services: AppServices
        let visits: Visits
        /// The workspaces of the session.
        let workspaces: Int
    }

    /// Runs `body` on the focused pane of a whole window of the `real` session. The New Tab key makes a New Tab page
    /// there, and the daemon's side of its creation waits until `body` ends.
    private static func withPane(_ body: @MainActor (Start) async throws -> Void) async throws {
        _ = NSApplication.shared
        let visits = Visits()
        // An inert address for each New Tab page: the pages load nothing.
        let environment = [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"]
        let services = AppServices(environment: AppEnvironment.current([:]), agentPaneEnvironment: environment,
                                   newTabPlaceSource: { visits.source($0) })
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
            // What the window's own start mapped is not a key's.
            _ = visits.take()
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

    /// One New Tab key. `made`: the tabs that the strip lists more than before the key, read in the key's own call.
    private static func newTab(_ start: Start) -> (ran: Bool, made: Int) {
        let before = Set(start.pane.orderedIDs.map(\.rawValue))
        let ran = start.services.registry.perform("newTab.default", invocation: ActionInvocation(origin: .user))
        return (ran, start.pane.orderedIDs.map(\.rawValue).filter { !before.contains($0) }.count)
    }

    /// The walk of each New Tab key's call as it was at the decision's date (`NewTabPage.places`), with the app's own
    /// map of a workspace: it adds nothing to the count.
    private static func walkAtTheDecision(_ services: AppServices)
        -> (tabs: [AgentPaneOmnibar.Tab], workspaces: [AgentPaneOmnibar.Workspace], folders: [String]) {
        let sources = services.machines.allWorkspaces.map { workspace, _ in NewTabPlaces.Source(workspace) }
        let current = services.windows.active?.state.workspaceID
        return NewTabPlaces(home: NSHomeDirectory()).places(sources, current: current, excluding: nil) {
            AppServices.dataURL(services.tabFavicon($0))
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
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
    /// page that has a view. The feed is the app's own (`NewTabPlacesFeed.wire`). The app starts it after its first
    /// frame and the fixture does not, so this test starts it. The feed lives as long as the process (the app's rule):
    /// this test leaves one feed behind.
    ///
    /// The sign that the feed ran is a condition of the setup: after the title change, the tab rows of a page are not
    /// the rows of before. Without the sign, a feed that did not run in the drain reads as `no map`.
    @Test func aChangeWithThreeOpenPagesMapsOneWorkspaceAtMostAfterIt() async throws {
        try await Self.withPane { start in
            let tabs = start.services.agentTabs
            NewTabPlacesFeed.wire(tabs, services: start.services)
            for _ in 0..<3 {
                let opened = Self.newTab(start)
                try #require(opened.ran && opened.made == 1,
                             "setup: a New Tab key \(opened.ran ? "ran" : "was refused") and the strip has \(opened.made) new tabs")
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
}
