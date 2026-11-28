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
        let isFocusedInWorkspace: Bool
        init(focused: Bool = false) { isFocusedInWorkspace = focused }
        func showSelected() { selectedContentIsAlive = true }
        func showWhileWaiting() {}
    }

    @Test(arguments: [false, true])
    func movingWithTheSurfaceBudgetSpentKeepsTheSourceDrawn(selectBeforeMove: Bool) async throws {
        let frames = ManualFrames()
        let fixture = try await MoveFixture(frames: frames)
        defer { fixture.close() }
        frames.fire()
        let other = BudgetPane()
        try #require(fixture.services.presentation.showNow(other))
        let sourceHost = fixture.source.view.contentHost
        let destinationHost = fixture.destination.view.contentHost
        let sourceFrame = sourceHost.frame, destinationFrame = destinationHost.frame
        fixture.move(selectBeforeMove: selectBeforeMove)
        await Self.nextCommittedPass()
        #expect(fixture.source.view.contentHost === sourceHost && sourceHost.frame == sourceFrame,
                "the unchanged source pane moved or replaced its content host")
        #expect(fixture.destination.view.contentHost === destinationHost && destinationHost.frame == destinationFrame,
                "the destination pane moved or replaced its content host")
        #expect(fixture.source.currentTabKey == fixture.history
                && fixture.movedPage.contentView.isDescendant(of: sourceHost),
                "the source lost its live page while its cold replacement waited for the surface budget")
        #expect(fixture.destination.currentTabKey == fixture.destinationHistory
                && fixture.destinationPage.contentView.isDescendant(of: destinationHost),
                "the destination changed its old page before the source replacement could show")
        #expect(fixture.services.cache.existingBrowser(fixture.blank) == nil,
                "the move bypassed the exhausted frame budget by creating its cold neighbor early")
        #expect(fixture.services.cache.presenter(of: fixture.history) === fixture.source,
                "the destination took ownership before the source could replace the moved page")
        // The destination can precede the source in the scheduler's queue; its retry then takes the following frame.
        for _ in 0..<3 {
            frames.fire()
            await Self.nextCommittedPass()
        }
        #expect(fixture.services.cache.existingBrowser(fixture.blank) != nil
                && fixture.source.currentTabKey == fixture.blank && fixture.source.view.hostsContent,
                "the cold neighbor did not show once the presentation budget became available")
        #expect(fixture.destination.currentTabKey == fixture.history
                && fixture.movedPage.contentView.isDescendant(of: destinationHost)
                && fixture.services.cache.presenter(of: fixture.history) === fixture.destination,
                "the deferred move never delivered the page and ownership to its real destination")
    }

    /// The store has removed the moved tab, but the source strip still selects its old warm page.
    /// Admission must not call that stale selection warm and then create its cold replacement in a spent frame.
    @Test func aStaleMoveSourceCannotCreateAfterAFocusedPaneSpentTheFrameBudget() async throws {
        let frames = ManualFrames()
        let fixture = try await MoveFixture(frames: frames)
        defer { fixture.close() }
        frames.fire()
        let focused = BudgetPane(focused: true)
        fixture.services.presentation.setNeedsShowSelected(focused)
        fixture.moveLeavingSourceStripStale()
        // No await or explicit source select/sync before fire: the observation task must not repair this race for us.
        try #require(fixture.source.stripModel.selectedID?.rawValue == fixture.history
                     && fixture.source.appliedRecordTabs != fixture.source.pane.tabs.map(\.id),
                     "fixture: the source strip caught up before the scheduler admitted it")
        try #require(fixture.services.cache.existingBrowser(fixture.blank) == nil)
        fixture.services.presentation.setNeedsShowSelected(fixture.source)
        frames.fire()
        try #require(focused.selectedContentIsAlive, "fixture: the focused pane did not consume this frame's cold budget")
        #expect(fixture.services.cache.existingBrowser(fixture.blank) == nil,
                "stale warm admission created a second cold surface after the focused pane spent the frame budget")
        #expect(fixture.source.currentTabKey == fixture.history
                && fixture.movedPage.contentView.isDescendant(of: fixture.source.view.contentHost),
                "the stale source lost the moved page before its replacement was eligible")
        #expect(fixture.destination.currentTabKey == fixture.destinationHistory
                && fixture.destinationPage.contentView.isDescendant(of: fixture.destination.view.contentHost),
                "the pending destination replaced its page during the spent frame")
        await Self.nextCommittedPass()
        #expect(fixture.services.cache.existingBrowser(fixture.blank) == nil,
                "a before-commit callback bypassed the same frame's exhausted creation budget")
        #expect(fixture.movedPage.contentView.isDescendant(of: fixture.source.view.contentHost)
                && fixture.destinationPage.contentView.isDescendant(of: fixture.destination.view.contentHost),
                "one of the panes committed without the page it retained during the stale-strip wait")
        for _ in 0..<3 {
            frames.fire()
            await Self.nextCommittedPass()
        }
        #expect(fixture.source.currentTabKey == fixture.blank && fixture.source.view.hostsContent)
        #expect(fixture.destination.currentTabKey == fixture.history
                && fixture.movedPage.contentView.isDescendant(of: fixture.destination.view.contentHost)
                && fixture.services.cache.presenter(of: fixture.history) === fixture.destination,
                "the stale source never caught up and delivered the deferred move")
    }

    /// A create/reopen reply names a cold tab already in the store; apply consumes its pending selection.
    /// That direct apply path must obey the same budget as ordinary clicks and stale-strip remapping.
    @Test(arguments: [false, true])
    func aPendingColdSelectionKeepsTheOldPageUntilItsFrame(reopened: Bool) async throws {
        let frames = ManualFrames()
        let fixture = try await Fixture(frames: frames)
        defer { fixture.close() }
        frames.fire()
        let other = BudgetPane()
        try #require(fixture.services.presentation.showNow(other))
        if reopened { fixture.pane.pendingSelect.tab = fixture.blank }
        else { fixture.pane.pendingSelect.surface = SurfaceID(rawValue: 2) }
        fixture.pane.syncStripFromStore()
        try #require(fixture.pane.pendingSelect.tab == nil && fixture.pane.pendingSelect.surface == nil
                     && fixture.pane.stripModel.selectedID?.rawValue == fixture.blank,
                     "fixture: apply did not consume the create/reopen selection")
        #expect(fixture.services.cache.existingBrowser(fixture.blank) == nil,
                "pendingSelect bypassed the exhausted creation budget")
        #expect(fixture.pane.currentTabKey == fixture.history
                && fixture.page.contentView.isDescendant(of: fixture.pane.view.contentHost),
                "pendingSelect discarded the old page before its cold replacement was eligible")
        await Self.nextCommittedPass()
        #expect(fixture.services.cache.existingBrowser(fixture.blank) == nil)
        #expect(fixture.page.contentView.isDescendant(of: fixture.pane.view.contentHost))
        frames.fire()
        #expect(fixture.pane.currentTabKey == fixture.blank && fixture.pane.view.hostsContent
                && fixture.services.cache.existingBrowser(fixture.blank) != nil,
                "the pending selection never showed after the frame budget became available")
    }

    /// Both panes want the other's already-loaded page. Waiting merely because a view still belongs
    /// to its old pane makes a cycle; warm selections must complete through the normal displacement path.
    @Test(arguments: [false, true])
    func reciprocalWarmMovesDoNotWaitForEachOther(sourceFirst: Bool) async throws {
        let frames = ManualFrames()
        let fixture = try await MoveFixture(frames: frames)
        defer { fixture.close() }
        frames.fire()
        let other = BudgetPane()
        try #require(fixture.services.presentation.showNow(other))
        let sourceHost = fixture.source.view.contentHost
        let destinationHost = fixture.destination.view.contentHost
        let sourceFrame = sourceHost.frame, destinationFrame = destinationHost.frame
        fixture.swapWarmPages(sourceFirst: sourceFirst)
        try #require(!fixture.source.stripIsStale && !fixture.destination.stripIsStale,
                     "fixture: both panes must have applied their swapped records before testing warm progress")
        try #require(fixture.source.stripModel.selectedID?.rawValue == fixture.destinationHistory
                     && fixture.destination.stripModel.selectedID?.rawValue == fixture.history,
                     "fixture: the panes did not select each other's warm pages")
        #expect(fixture.services.cache.existingBrowser(fixture.blank) == nil,
                "a reciprocal warm move created the unrelated cold neighbor")
        // A deferred first pane may wait one frame for the other strip to catch up, then one more
        // for its displacement callback. The bounded loop exposes a mutual wait rather than hanging.
        for _ in 0..<3 {
            frames.fire()
            await Self.nextCommittedPass()
            #expect(fixture.services.cache.existingBrowser(fixture.blank) == nil)
        }
        #expect(fixture.source.currentTabKey == fixture.destinationHistory
                && fixture.destinationPage.contentView.isDescendant(of: sourceHost)
                && fixture.services.cache.presenter(of: fixture.destinationHistory) === fixture.source,
                "the source waited forever for a warm page the destination was ready to release")
        #expect(fixture.destination.currentTabKey == fixture.history
                && fixture.movedPage.contentView.isDescendant(of: destinationHost)
                && fixture.services.cache.presenter(of: fixture.history) === fixture.destination,
                "the destination waited forever for a warm page the source was ready to release")
        #expect(fixture.source.view.contentHost === sourceHost && sourceHost.frame == sourceFrame)
        #expect(fixture.destination.view.contentHost === destinationHost && destinationHost.frame == destinationFrame)
    }

    @Test func aDeferredMoveDoesNotOverrideANewerDestinationSelection() async throws {
        let frames = ManualFrames()
        let fixture = try await MoveFixture(frames: frames)
        defer { fixture.close() }
        frames.fire()
        let other = BudgetPane()
        try #require(fixture.services.presentation.showNow(other))
        fixture.move(selectBeforeMove: true)
        try #require(fixture.destination.currentTabKey == fixture.destinationHistory)
        fixture.select(fixture.destinationHistory, in: fixture.destination)
        for _ in 0..<3 {
            frames.fire()
            await Self.nextCommittedPass()
        }
        #expect(fixture.source.currentTabKey == fixture.blank && fixture.source.view.hostsContent)
        #expect(fixture.destination.currentTabKey == fixture.destinationHistory
                && fixture.destinationPage.contentView.isDescendant(of: fixture.destination.view.contentHost),
                "a stale deferred move replaced the destination's newer selection")
        #expect(fixture.services.cache.presenter(of: fixture.history) !== fixture.destination,
                "a cancelled destination selection still took ownership of the moved tab")
    }

    /// Two actual presenters, with a warm History page in each and one never-created source neighbor.
    /// Store updates move the tab; only the test controls which pane takes its new strip selection first.
    @MainActor private struct MoveFixture {
        let services: AppServices
        let source: PaneController, destination: PaneController
        let state: WindowState
        let window: NSWindow
        let history: String, blank: String, destinationHistory: String
        let movedPage: HistoryPageTab, destinationPage: HistoryPageTab

        private static func tree(moved: Bool) -> DaemonTree {
            let history = TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .browser, url: URL.historyPageString,
                                      browserRenderer: "frontend", browserEngine: "webkit")
            let blank = TabSnapshot(surface: SurfaceID(rawValue: 2), kind: .browser, title: "Blank", url: "about:blank",
                                    browserRenderer: "frontend", browserEngine: "webkit")
            let other = TabSnapshot(surface: SurfaceID(rawValue: 4), kind: .browser, url: URL.historyPageString,
                                    browserRenderer: "frontend", browserEngine: "webkit")
            let first = PaneID(rawValue: 1), second = PaneID(rawValue: 2)
            let layout = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.5,
                                          a: .leaf(first), b: .leaf(second))
            let panes = [PaneSnapshot(id: first, tabs: moved ? [blank] : [history, blank]),
                         PaneSnapshot(id: second, tabs: moved ? [other, history] : [other])]
            let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: panes)
            return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
        }

        init(frames: ManualFrames) async throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            services.presentation.frames = frames
            services.launchReveal.markAllReady()
            let store = services.daemon.store
            store.connectionState = .connected(try UnloadedTabKeepsPaneTests.connected())
            store.apply(snapshot: Self.tree(moved: false))
            let models = try #require(store.workspaces.first?.screens.first?.panes)
            let sourceModel = try #require(models.first { $0.handle == PaneID(rawValue: 1) })
            let destinationModel = try #require(models.first { $0.handle == PaneID(rawValue: 2) })
            history = try #require(store.tab(surface: SurfaceID(rawValue: 1))).id
            blank = try #require(store.tab(surface: SurfaceID(rawValue: 2))).id
            destinationHistory = try #require(store.tab(surface: SurfaceID(rawValue: 4))).id
            movedPage = HistoryPageTab(id: BrowserTabID(rawValue: history), engine: .webkit, profile: .default, webPage: nil)
            destinationPage = HistoryPageTab(id: BrowserTabID(rawValue: destinationHistory), engine: .webkit, profile: .default, webPage: nil)
            _ = services.cache.install(movedPage, for: history)
            _ = services.cache.install(destinationPage, for: destinationHistory)
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
            state = WindowState(record: record)
            source = PaneController(pane: sourceModel, daemon: services.daemon, layoutPaneID: LayoutPaneID(sourceModel.id), services: services, state: state)
            destination = PaneController(pane: destinationModel, daemon: services.daemon, layoutPaneID: LayoutPaneID(destinationModel.id), services: services, state: state)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
            source.view.frame = NSRect(x: 0, y: 0, width: 450, height: 400)
            destination.view.frame = NSRect(x: 450, y: 0, width: 450, height: 400)
            root.addSubview(source.view)
            root.addSubview(destination.view)
            window.contentView = root
            window.orderFrontRegardless()
            source.setPresence(.visible)
            destination.setPresence(.visible)
            select(history, in: source)
            select(destinationHistory, in: destination)
            root.layoutSubtreeIfNeeded()
            frames.fire()
            await UnloadedTabKeepsPaneTests.nextCommittedPass()
            try #require(source.currentTabKey == history && movedPage.contentView.isDescendant(of: source.view.contentHost),
                         "fixture: the source History page never showed")
            try #require(destination.currentTabKey == destinationHistory
                         && destinationPage.contentView.isDescendant(of: destination.view.contentHost),
                         "fixture: the destination History page never showed")
            try #require(services.cache.existingBrowser(blank) == nil, "fixture: the cold neighbor was already created")
        }

        func select(_ key: String, in pane: PaneController) {
            state.selection.select(key, in: pane.paneKey)
            pane.syncStripFromStore()
        }

        func move(selectBeforeMove: Bool) {
            if selectBeforeMove { select(blank, in: source) }
            services.daemon.store.apply(snapshot: Self.tree(moved: true))
            select(history, in: destination)
            if !selectBeforeMove { select(blank, in: source) }
        }

        /// Both records change before either strip applies them.
        func swapWarmPages(sourceFirst: Bool) {
            let history = TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .browser, url: URL.historyPageString,
                                      browserRenderer: "frontend", browserEngine: "webkit")
            let blank = TabSnapshot(surface: SurfaceID(rawValue: 2), kind: .browser, title: "Blank", url: "about:blank",
                                    browserRenderer: "frontend", browserEngine: "webkit")
            let other = TabSnapshot(surface: SurfaceID(rawValue: 4), kind: .browser, url: URL.historyPageString,
                                    browserRenderer: "frontend", browserEngine: "webkit")
            let first = PaneID(rawValue: 1), second = PaneID(rawValue: 2)
            let layout = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.5,
                                          a: .leaf(first), b: .leaf(second))
            let panes = [PaneSnapshot(id: first, tabs: [other, blank]),
                         PaneSnapshot(id: second, tabs: [history])]
            let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: panes)
            services.daemon.store.apply(snapshot: DaemonTree(workspaces: [
                WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])
            ]))
            state.selection.select(destinationHistory, in: source.paneKey)
            state.selection.select(self.history, in: destination.paneKey)
            let ordered = sourceFirst ? [source, destination] : [destination, source]
            for pane in ordered { pane.syncStripFromStore() }
        }

        func moveLeavingSourceStripStale() {
            services.daemon.store.apply(snapshot: Self.tree(moved: true))
            select(history, in: destination)
        }

        func close() {
            source.teardown()
            destination.teardown()
            window.close()
            services.cache.browsers[history] = nil
            services.cache.browsers[destinationHistory] = nil
            services.cache.release(blank)
        }
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
