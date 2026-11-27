import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Cmd-W on a pane's last tab, and the daemon refuses the close: the pane comes back with its tab in its tab bar.
///
/// The key's turn takes the tab out of the tab bar's model and the pane out of the layout. The pane's view shows until
/// the next frame hides it, and its tab bar keeps the tab until then (`TabStripSyncHold`,
/// `PaneCloseTabGoesWithItsPaneTests`). A refusal puts the tab and the pane back. What the screen must never show
/// then: the pane at its place, with an empty tab bar (only the new-tab button).
///
/// Each test here is a guard of the refused path, and none has a red run. By a read of the code the first two pass
/// without the hold too: a tab bar without it drops the tab in the key's turn, and after the refusal it makes the
/// tab's cell again, in its usual sync or in its one sync when it shows. They fail when a refusal leaves the pane on
/// the screen without its tab: a hold that still keeps the tab bar from its model, or a tab bar that comes back and
/// does not sync. The third also wants the cell that the tab bar kept, before the pane hides and after it comes back,
/// so by a read it fails without the hold.
///
/// The clock and the store are those of `PaneCloseTabGoesWithItsPaneTests` (a manual 120 Hz clock, an offline store).
/// The first two tests make the one call of the tab bar's own job (`TabStripView.syncFromModel()`) themselves, after
/// each frame tick. The third makes no such call: the tab bar hears of its model as it does in the app, and the test
/// reads each frame directly after its tick. Each test runs the work that follows a frame's commit where it says so
/// (`Fixture.committed`).
@Suite(.closesItsWindows)
@MainActor struct PaneCloseRefusedTabTests {
    typealias Fixture = ClosedPaneContentStaysUntilLandingTests.Fixture

    static let dt = ClosedPaneContentStaysUntilLandingTests.dt
    /// The most frame ticks a test steps before it says that the pane never hid, or never showed again.
    static let frames = 8

    /// The key's turn of Cmd-W on the last tab of pane 2 (`PaneController.prepareClose`), then the tab bar's sync.
    private static func closeLastTab(in app: Fixture) throws
        -> (pane: PaneController, strip: TabStripView, tab: StripTabID, host: PaneHostView, prepared: PreparedTabClose) {
        // The columns that stay share the window after a close: the close changes a pane's size, so it shows at a
        // frame tick and not in the key's own turn.
        app.content.layoutModel.newColumnWidthModeOverride = .fitScreen
        app.content.applyCurrent()
        app.settle()

        let pane = try app.pane(2)
        let strip = pane.view.stripView
        let tabs = pane.stripModel.orderedTabs.map(\.id)
        try #require(tabs.count == 1, "SETUP: the pane has \(tabs.count) tabs, not 1")
        strip.syncFromModel()
        try #require(strip.isShownInWindow, "SETUP: the pane's tab bar does not count as shown in its window")
        try #require(strip.cells[tabs[0]] != nil, "SETUP: the tab bar does not show the pane's tab before the close")
        let host = try #require(app.root.context.hosts[pane.layoutPaneID], "SETUP: the pane has no host in the layout")
        try #require(host.superview != nil && !host.isHiddenOrHasHiddenAncestor, "SETUP: the pane does not show before the close")

        let prepared = try #require(pane.prepareClose(tabs), "SETUP: the close has no daemon tab")
        try #require(pane.stripModel.tabs.isEmpty, "SETUP: the key's turn left the tab in the tab bar's model")
        try #require(app.content.layoutModel.isClosing(pane.layoutPaneID), "SETUP: the key's turn did not show the pane's close")
        try #require(host.superview != nil && !host.isHidden,
                     "SETUP: the key's own turn hid the pane, so no frame shows the pane after the key")
        // Between the key's turn and the frame tick: the tab bar follows its model.
        strip.syncFromModel()
        return (pane, strip, tabs[0], host, prepared)
    }

    /// A refusal before the frame that hides the pane: the pane never left the screen, and its tab bar shows its tab
    /// in each frame.
    @Test(.timeLimit(.minutes(1)))
    func aCloseRefusedBeforeThePaneHidesKeepsThePaneAndItsTab() async throws {
        let app = try await Fixture()
        defer { app.close() }
        let close = try Self.closeLastTab(in: app)

        // The daemon refused, before a frame tick.
        await close.prepared.finish(true, false)
        try #require(close.pane.stripModel.tabs.map(\.id) == [close.tab], "SETUP: the refusal did not put the tab back in the tab bar's model")
        try #require(!app.content.layoutModel.isClosing(close.pane.layoutPaneID), "SETUP: the refusal did not take back the pane's close")
        close.strip.syncFromModel()

        // The refusal's turn (frame 0), then three frame ticks, each with the work that follows its commit.
        for frame in 0...3 {
            if frame > 0 {
                _ = app.root.advanceFrame(Self.dt)
                close.strip.syncFromModel()
            }
            app.committed.run()
            #expect(app.root.context.hosts[close.pane.layoutPaneID] === close.host, "frame \(frame): the pane does not have the host it had before the close")
            #expect(!close.host.isLeaving, "frame \(frame): the pane's host still says that its pane leaves")
            #expect(!close.strip.isInALeavingPane, "frame \(frame): a view in the pane that came back says that its pane leaves")
            #expect(close.host.superview != nil && !close.host.isHiddenOrHasHiddenAncestor, "frame \(frame): the pane does not show")
            #expect(close.strip.cells[close.tab] != nil, "frame \(frame): the pane shows with an empty tab bar after the refusal")
            #expect(Set(close.strip.cells.keys) == Set(close.pane.stripModel.tabs.map(\.id)),
                    "frame \(frame): the tab bar's cells are not its model's tabs")
        }
    }

    /// What a view in a closed pane says of its pane (`NSView.isInALeavingPane`), with the layout's true host. From
    /// the key's turn to the frame that hides the pane, the pane shows at its place and each view in it says that its
    /// pane leaves; a view in a pane that stays does not. After the frame that hides the pane, no view says it.
    /// A walk that looks for the pane at a place reads this (the lookup of the agent pane under a page window).
    ///
    /// `moves`: the fixture asks for the panes' move at a close (`PaneCommitMotion`). The closed pane then stays, under
    /// the pane that takes its room, to the frame that ends the move: that is the time in which 2 panes are at one
    /// place, and each frame of it must have the answer.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aViewInAClosedPaneSaysThatItsPaneLeavesUntilTheFrameThatHidesIt(moves: Bool) async throws {
        let app = try await Fixture()
        defer { app.close() }
        if moves { app.root.context.commitMotionOverride = true }
        let close = try Self.closeLastTab(in: app)
        let stays = try app.pane(1)
        await Self.runQueuedJobs()
        try #require(close.host.superview != nil && !close.host.isHidden, "SETUP: the closed pane does not show before the first frame tick")
        #expect(close.host.isLeaving, "the closed pane shows, and its host does not say that its pane leaves")
        #expect(close.strip.isInALeavingPane && close.pane.view.isInALeavingPane,
                "the closed pane shows, and a view in it does not say that its pane leaves: its tab bar \(close.strip.isInALeavingPane), its content \(close.pane.view.isInALeavingPane)")
        #expect(!stays.view.isInALeavingPane && !stays.view.stripView.isInALeavingPane, "a view in a pane that stays says that its pane leaves")

        var hidden: Int?
        var wrong: [Int] = []
        // The frames before the hide in which a pane of the screen had a move on its layer.
        var moved = 0
        let screen = try #require(app.root.screenViews.values.first { !$0.isHidden }, "SETUP: the layout shows no screen")
        // The frame that ends the move hides the pane. The limit has room for a move of 0.3 s (36 frames of this clock).
        let most = moves ? Self.frames + 40 : Self.frames
        for frame in 1...most {
            _ = app.root.advanceFrame(Self.dt)
            if close.host.isHidden || close.host.superview == nil {
                hidden = frame
                break
            }
            if PaneCommitMotionTests.inFlight(screen) { moved += 1 }
            if !close.strip.isInALeavingPane || !close.pane.view.isInALeavingPane || stays.view.isInALeavingPane { wrong.append(frame) }
        }
        let frame = try #require(hidden, "SETUP: no frame of \(most) hid the closing pane")
        let movesAtTheHide = PaneCommitMotionTests.inFlight(screen)
        print("PaneCloseRefusedTabTests: a view in a closed pane, the close moves its panes: \(moves): frame \(frame) hid the pane; a pane had a move "
            + "on its layer in \(moved) frame(s) before it, and at the hide: \(movesAtTheHide); the frames before it "
            + "in which a view in the closed pane did not say that its pane leaves, or a view in the pane that stays said it: \(wrong); after the hide "
            + "the host says that its pane leaves: \(close.host.isLeaving), a view in it: \(close.strip.isInALeavingPane), want false for both")
        #expect(wrong.isEmpty, "the closed pane shows in the frames \(wrong), and a view in it does not say that its pane leaves, or a view in the pane that stays says it")
        // Without these the case with the move proves no more than the case without it. The bound is the motion's own
        // state, not a frame count: the pane showed while a pane moved, and the hide is not before the move's last frame.
        if moves {
            #expect(moved > 0, "SETUP: the pane hid in frame \(frame) and no pane had a move on its layer before it: no pane moved at this close")
            #expect(!movesAtTheHide, "frame \(frame) hid the closed pane, and a pane of the screen still has a move on its layer")
        }
        #expect(!close.host.isLeaving && !close.strip.isInALeavingPane, "after the frame that hid the closed pane, its host or a view in it says that the pane leaves")
        #expect(!stays.view.isInALeavingPane, "after the close's frame a view in the pane that stays says that its pane leaves")
    }

    /// A refusal after the frame that hid the pane: each frame that shows the pane again shows its tab.
    ///
    /// The frame that shows a close hides the closed pane's view, and the work after that frame's commit takes the view
    /// and its pane's controller down. A refusal comes before that work (the same view and tab bar show again; a tab bar
    /// that kept its tab owes one sync then, `TabStripSyncHold.takeOwedSync()`) or after it (the layout makes the pane
    /// a new view and a new tab bar). `tornDown`: the refusal comes after that work.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aCloseRefusedAfterThePaneHidBringsThePaneBackWithItsTab(tornDown: Bool) async throws {
        let app = try await Fixture()
        defer { app.close() }
        let close = try Self.closeLastTab(in: app)

        // Each frame tick until the one that hides the pane.
        var hidden: Int?
        for frame in 1...Self.frames {
            _ = app.root.advanceFrame(Self.dt)
            if close.host.isHidden || close.host.superview == nil {
                hidden = frame
                break
            }
            close.strip.syncFromModel()
        }
        _ = try #require(hidden, "SETUP: no frame of \(Self.frames) hid the closing pane")
        if tornDown {
            // The work after the commit of the frame that hid the pane, and the work that it queued.
            app.committed.run()
            app.committed.run()
            try #require(close.host.superview == nil, "SETUP: the work after the frame's commit left the closed pane's view in the window")
        }

        // The daemon refused.
        await close.prepared.finish(true, false)
        let pane = try app.pane(2)
        try #require((pane === close.pane) == !tornDown, "SETUP: the pane that came back has \(tornDown ? "the controller that was taken down" : "a new controller")")
        try #require(pane.stripModel.tabs.map(\.id) == [close.tab], "SETUP: the refusal did not put the tab back in the tab bar's model")
        let strip = pane.view.stripView
        strip.syncFromModel()
        // The work after the commit of the frame that hid the pane comes after the refusal: it must not take the pane.
        if !tornDown { app.committed.run() }

        // The refusal's turn (frame 0), then each frame tick: a frame that shows the pane shows its tab.
        var shown: [Int] = [], bare: [Int] = []
        for frame in 0...Self.frames {
            if frame > 0 {
                _ = app.root.advanceFrame(Self.dt)
                strip.syncFromModel()
                app.committed.run()
            }
            guard let host = app.root.context.hosts[pane.layoutPaneID], host.superview != nil, !host.isHiddenOrHasHiddenAncestor else { continue }
            shown.append(frame)
            if strip.cells[close.tab] == nil || !strip.isShownInWindow || strip.isHiddenOrHasHiddenAncestor { bare.append(frame) }
        }
        #expect(!shown.isEmpty, "no frame of \(Self.frames) showed the pane again after the refusal")
        #expect(shown.last == Self.frames, "the pane that came back went again: it showed in the frames \(shown) of \(Self.frames)")
        #expect(bare.isEmpty, "the pane that came back shows without its tab in its tab bar in the frames \(bare)")
    }

    /// The main actor runs what is queued, as it does in the app before the next frame tick: the tab bar's own job
    /// (`TabStripView.startObserving()`) and each pane's. A fixed number of yields, no wait for time to pass.
    private static func runQueuedJobs() async {
        for _ in 0..<50 { await Task.yield() }
    }

    /// Whether the window shows `host`: in the window, not hidden, with a size.
    private static func shows(_ host: PaneHostView?) -> Bool {
        guard let host else { return false }
        return host.superview != nil && !host.isHiddenOrHasHiddenAncestor && host.frame.width >= 1 && host.frame.height >= 1
    }

    /// The refusal after the frame that hid the pane, with no sync call of the test. The queued jobs run before each
    /// frame tick, and the test reads what a frame shows directly after its tick, before the work that follows its
    /// commit. It reads the end of the refusal's own turn too (frame 0).
    ///
    /// With the view that the pane had (`tornDown` false) the tab's cell is the one that the tab bar kept: a tab bar
    /// that drops the kept cell and makes it again is a fault here.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aCloseRefusedAfterThePaneHidShowsItsTabWithNoSyncCallOfTheTest(tornDown: Bool) async throws {
        let app = try await Fixture()
        defer { app.close() }
        // As in `closeLastTab`: the close changes a pane's size, so it shows at a frame tick.
        app.content.layoutModel.newColumnWidthModeOverride = .fitScreen
        app.content.applyCurrent()
        app.settle()
        await Self.runQueuedJobs()

        let closed = try app.pane(2)
        let oldStrip = closed.view.stripView
        let tabs = closed.stripModel.orderedTabs.map(\.id)
        try #require(tabs.count == 1, "SETUP: the pane has \(tabs.count) tabs, not 1")
        let tab = tabs[0]
        let kept = try #require(oldStrip.cells[tab], "SETUP: the tab bar does not show the pane's tab before the close")
        try #require(oldStrip.isShownInWindow, "SETUP: the pane's tab bar does not count as shown in its window")
        let oldHost = try #require(app.root.context.hosts[closed.layoutPaneID], "SETUP: the pane has no host in the layout")
        try #require(Self.shows(oldHost), "SETUP: the pane does not show before the close")

        let prepared = try #require(closed.prepareClose(tabs), "SETUP: the close has no daemon tab")
        try #require(closed.stripModel.tabs.isEmpty, "SETUP: the key's turn left the tab in the tab bar's model")
        try #require(Self.shows(oldHost), "SETUP: the key's own turn hid the pane, so no frame shows the pane after the key")

        // Each frame tick until the one that hides the pane: while the pane shows, its tab bar shows the tab's cell.
        var hidden: Int?
        for frame in 1...Self.frames {
            await Self.runQueuedJobs()
            if Self.shows(oldHost) {
                #expect(oldStrip.cells[tab] === kept, "before frame \(frame): the pane that leaves shows without its tab's cell")
            }
            _ = app.root.advanceFrame(Self.dt)
            if !Self.shows(oldHost) {
                hidden = frame
                break
            }
            #expect(oldStrip.cells[tab] === kept, "frame \(frame): the pane that leaves shows without its tab's cell")
        }
        _ = try #require(hidden, "SETUP: no frame of \(Self.frames) hid the closing pane")
        if tornDown {
            // The work after the commit of the frame that hid the pane, and the work that it queued.
            app.committed.run()
            app.committed.run()
            try #require(oldHost.superview == nil, "SETUP: the work after the frame's commit left the closed pane's view in the window")
        }

        // The daemon refused.
        await prepared.finish(true, false)
        let pane = try app.pane(2)
        try #require((pane === closed) == !tornDown, "SETUP: the pane that came back has \(tornDown ? "the controller that was taken down" : "a new controller")")
        try #require(pane.stripModel.tabs.map(\.id) == [tab], "SETUP: the refusal did not put the tab back in the tab bar's model")
        let strip = pane.view.stripView

        // The end of the refusal's turn (frame 0), then each frame tick: a frame that shows the pane shows its tab.
        var shown: [Int] = [], bare: [Int] = [], madeAgain: [Int] = []
        for frame in 0...Self.frames {
            if frame > 0 {
                await Self.runQueuedJobs()
                _ = app.root.advanceFrame(Self.dt)
            }
            if Self.shows(app.root.context.hosts[pane.layoutPaneID]) {
                shown.append(frame)
                if strip.cells[tab] == nil || !strip.isShownInWindow || strip.isHiddenOrHasHiddenAncestor {
                    bare.append(frame)
                } else if !tornDown, strip.cells[tab] !== kept {
                    madeAgain.append(frame)
                }
            }
            // The work after a frame's commit. At frame 0 with the pane's old view it is the work of the frame that hid
            // the pane, which comes after the refusal: it must not take the pane.
            if frame > 0 || !tornDown { app.committed.run() }
        }
        #expect(!shown.isEmpty, "no frame of \(Self.frames) showed the pane again after the refusal")
        #expect(shown.last == Self.frames, "the pane that came back went again: it showed in the frames \(shown) of \(Self.frames)")
        #expect(bare.isEmpty, "the pane that came back shows without its tab in its tab bar in the frames \(bare)")
        #expect(madeAgain.isEmpty, "the tab bar dropped the cell that it kept and made it again: the frames \(madeAgain)")
    }
}

/// A view that holds a tab bar as a pane's host does, for what the tab bar asks of it (`PaneLeaving`).
private final class LeavingPaneHostStub: NSView, PaneLeaving {
    var isLeaving = false
}

/// The rule of `TabStripSyncHold` alone: a tab bar that kept the tabs of a pane that leaves owes one sync when it
/// shows again (`TabStripSyncHold.takeOwedSync()`), also when no call and no job told it that its model changed.
///
/// The test is not async and makes no sync call after the hold, so the tab bar's own job (its model's observation)
/// does not run: the one sync at the show is the hold's. It has no red run. By a read of the code it fails when
/// `takeOwedSync()` does not count the kept tabs. By a read of the refusal's routes in the app, each of them tells
/// the tab bar by another call too, so this test holds the type's rule and not a state that the app reaches.
@MainActor @Suite(.closesItsWindows, .serialized) struct TabStripLeavingPaneSyncTests {
    @Test func aStripThatKeptALeavingPanesTabSyncsOnceWhenItShowsAgain() throws {
        let old = StripTabID("old"), new = StripTabID("new")
        let model = TabStripModel(tabs: [TabItem(id: old, title: "Old")], selectedID: old)
        let strip = TabStripView(model: model)
        let host = LeavingPaneHostStub(frame: NSRect(x: 0, y: 0, width: 700, height: 40))
        strip.frame = NSRect(x: 0, y: 0, width: 700, height: TabStripView.preferredHeight)
        host.addSubview(strip)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.contentView = host
        strip.layoutSubtreeIfNeeded()
        try #require(strip.cells[old] != nil, "SETUP: the tab bar does not show its tab")
        try #require(strip.isShownInWindow, "SETUP: the tab bar does not count as shown in its window")

        // The key's turn of a close of the pane's last tab: the pane leaves, and the model has no tab.
        host.isLeaving = true
        model.tabs = []
        strip.syncFromModel()
        try #require(strip.cells[old] != nil, "SETUP: the tab bar of a pane that leaves dropped its last tab before the pane hid")

        // The frame that hides the pane. Then the pane gets another tab, and no call tells the tab bar. Then it shows.
        host.isLeaving = false
        host.isHidden = true
        try #require(!strip.isShownInWindow, "SETUP: the tab bar of a hidden pane counts as shown")
        model.tabs = [TabItem(id: new, title: "New")]
        model.selectedID = new
        host.isHidden = false
        #expect(strip.isShownInWindow, "the tab bar of the pane that shows again does not count as shown")
        #expect(Set(strip.cells.keys) == [new],
                "the tab bar that shows again did not sync: it shows \(strip.cells.keys.map(\.rawValue).sorted())")
    }
}
