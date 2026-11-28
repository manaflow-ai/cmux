import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextControl
@testable import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextTestSupport
import Foundation
import Testing

/// "when i click on an unloaded tab of anything at all the whole pane re-renders still on this version" and "likewise
/// when i move one tab completely to another pane, the original pane flickers a re-render" (Leo, 2026-11-22). A switch to
/// a tab with no content yet (restored at launch, opened in the background, hibernated) went through
/// `PaneController.presentSelection`'s first-visit path, which emptied the pane at once and made the tab's content on the
/// next frame: a frame of the bare pane between the two tabs, for every kind of tab. A tab moved out of a pane left it
/// empty the same way until the frame after, when the neighbor it selected had no content yet. The pane now keeps what it
/// shows until the new content is in, and a pane left with nothing shows its selection in the same turn.
@Suite(.serialized, .closesItsWindows)
@MainActor struct UnloadedTabKeepsPaneTests {
    private static func tree() -> DaemonTree {
        let tabs = [TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .browser, url: URL.historyPageString,
                                browserRenderer: "frontend", browserEngine: "webkit"),
                    TabSnapshot(surface: SurfaceID(rawValue: 2), kind: .browser, title: "Blank", url: "about:blank",
                                browserRenderer: "frontend", browserEngine: "webkit"),
                    TabSnapshot(surface: SurfaceID(rawValue: 3), title: "~")]
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: tabs)
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"unloaded-tab-keeps-pane-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// Waits until the main run loop's pass has committed (a one-shot before-waiting observer after every other one).
    private static func nextCommittedPass() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                              false, CFIndex.max) { _, _ in
                done.resume()
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
        }
    }

    /// Only the test advances presentation, so a run-loop commit cannot silently replenish the surface budget.
    private final class ManualFrames: ControlFrameSource, @unchecked Sendable {
        nonisolated(unsafe) private var pending: [@MainActor @Sendable () -> Void] = [] // main actor only
        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) { pending.append(work) }
        @MainActor func fire() {
            let due = pending
            pending = []
            due.forEach { $0() }
        }
    }

    /// A second pane uses this frame's one cold presentation before the move.
    private final class BudgetPane: PresentablePane {
        var selectedContentIsAlive = false
        var isFocusedInWorkspace: Bool { false }
        func showSelected() { selectedContentIsAlive = true }
        func showWhileWaiting() {}
    }

    @Test(arguments: [false, true])
    func movingWithTheSurfaceBudgetSpentKeepsTheSourceDrawn(selectBeforeMove: Bool) async throws {
        let frames = ManualFrames()
        let fixture = try await Fixture(frames: frames)
        defer { fixture.close() }
        frames.fire()
        let other = BudgetPane()
        try #require(fixture.services.presentation.showNow(other))
        let host = fixture.pane.view.contentHost
        let hostFrame = host.frame
        let taker = TakingPane()
        if selectBeforeMove { fixture.select(fixture.blank) }
        fixture.services.cache.present(fixture.history, by: taker, presence: .visible)
        if !selectBeforeMove { fixture.select(fixture.blank) }
        await Self.nextCommittedPass()
        #expect(fixture.pane.view.contentHost === host && host.frame == hostFrame,
                "the unchanged source pane moved or replaced its content host")
        #expect(fixture.pane.view.hostsContent || fixture.pane.view.launchImageView?.superview === host,
                "the source pane committed empty while a cold neighbor waited for the spent surface budget")
        frames.fire()
        #expect(fixture.pane.currentTabKey == fixture.blank && fixture.pane.view.hostsContent,
                "the cold neighbor did not replace the held frame when its presentation became eligible")
    }

    /// The pane the moved tab goes to: it takes the tab's view from the source pane (`TabContentCache.present`).
    private final class TakingPane: SurfacePresenter {
        func surfaceWasDisplaced(_ key: String) {}
        func surfaceIsFree(_ key: String) {}
    }

    /// A pane in a window showing the History page (tab 1), with a never-shown browser (tab 2) and terminal (tab 3).
    @MainActor private struct Fixture {
        let services: AppServices
        let pane: PaneController
        let state: WindowState
        let window: NSWindow
        let history: String, blank: String, terminal: String
        let page: HistoryPageTab

        init(frames: (any ControlFrameSource)? = nil) async throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            if let frames { services.presentation.frames = frames }
            let store = services.daemon.store
            store.connectionState = .connected(try UnloadedTabKeepsPaneTests.connected())
            store.apply(snapshot: UnloadedTabKeepsPaneTests.tree())
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            history = try #require(store.tab(surface: SurfaceID(rawValue: 1))).id
            blank = try #require(store.tab(surface: SurfaceID(rawValue: 2))).id
            terminal = try #require(store.tab(surface: SurfaceID(rawValue: 3))).id
            page = HistoryPageTab(id: BrowserTabID(rawValue: history), engine: .webkit, profile: .default, webPage: nil)
            _ = services.cache.install(page, for: history)
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
            state = WindowState(record: record)
            pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services, state: state)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            pane.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
            window.contentView = pane.view
            window.orderFrontRegardless()
            pane.setPresence(.visible)
            state.selection.select(history, in: pane.paneKey)
            pane.syncStripFromStore()
            pane.view.layoutSubtreeIfNeeded()
            for _ in 0..<12 where pane.currentTabKey != history || page.contentView.window == nil { await UnloadedTabKeepsPaneTests.nextCommittedPass() }
            try #require(pane.currentTabKey == history && pane.view.hostsContent, "the History page never showed")
            try #require(services.cache.existingBrowser(blank) == nil && services.cache.existingTerminal(terminal) == nil,
                         "fixture: tabs 2 and 3 were shown before")
        }

        func close() {
            pane.teardown()
            window.close()
            services.cache.browsers[history] = nil
            services.cache.release(blank)
        }

        /// The person selects `key` (a click goes through the same path: `applySelection` -> `presentSelection`).
        func select(_ key: String) {
            state.selection.select(key, in: pane.paneKey)
            pane.syncStripFromStore()
        }
    }

    /// A click on an unloaded tab, of each kind the pane makes on a first visit: in no committed pass between the click
    /// and the new tab's content is the pane empty. Fails before the fix: the first-visit path emptied the pane in the
    /// click's own pass (`letGo(parks: true)`).
    @Test(arguments: ["browser", "terminal"])
    func aClickOnAnUnloadedTabNeverEmptiesThePane(kind: String) async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let target = kind == "browser" ? fixture.blank : fixture.terminal
        fixture.select(target)
        try #require(fixture.pane.stripModel.selectedID?.rawValue == target, "the strip did not select the unloaded tab")
        var emptyPasses = fixture.pane.view.hostsContent ? 0 : 1
        for _ in 0..<12 where fixture.pane.currentTabKey != target {
            await Self.nextCommittedPass()
            if !fixture.pane.view.hostsContent, fixture.pane.currentTabKey != target { emptyPasses += 1 }
        }
        #expect(emptyPasses == 0, "the pane showed nothing for \(emptyPasses) committed pass(es) between the click and the \(kind) tab")
        #expect(fixture.pane.currentTabKey == target, "the unloaded \(kind) tab never showed")
    }

    /// The source pane of a tab move, when the move's view leaves before the pane learns its new selection: the
    /// neighbor it then selects, never shown, shows in that same pass. Fails before the fix: the pane stayed empty until
    /// the next display frame.
    @Test func aMoveThatLeavesThePaneEmptyShowsTheNeighborInTheSamePass() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let taker = TakingPane()
        fixture.services.cache.present(fixture.history, by: taker, presence: .visible) // the other pane takes the view
        try #require(!fixture.pane.view.hostsContent, "the move did not take the History page's view")
        fixture.select(fixture.blank)
        #expect(fixture.pane.currentTabKey == fixture.blank && fixture.pane.view.hostsContent,
                "the source pane stayed empty after the move (shows \(fixture.pane.currentTabKey ?? "nothing"))")
    }

    /// The other order: the source pane selects the never-shown neighbor first (it keeps the moving tab drawn), then the
    /// destination takes the view. The neighbor shows before the pass commits, never a frame later.
    @Test func aMoveAfterTheNeighborIsSelectedShowsItBeforeTheCommit() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        fixture.select(fixture.blank)
        try #require(fixture.pane.view.hostsContent, "the pane emptied when it selected the unloaded neighbor")
        let taker = TakingPane()
        fixture.services.cache.present(fixture.history, by: taker, presence: .visible)
        await Self.nextCommittedPass()
        #expect(fixture.pane.currentTabKey == fixture.blank && fixture.pane.view.hostsContent,
                "the source pane was empty at the commit after the move (shows \(fixture.pane.currentTabKey ?? "nothing"))")
    }
}
