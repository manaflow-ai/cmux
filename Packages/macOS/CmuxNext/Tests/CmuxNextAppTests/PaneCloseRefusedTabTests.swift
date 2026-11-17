import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
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
/// Each test here is a guard of the refused path, and none has a red run. By a read of the code each passes without
/// the hold too: a tab bar without it drops the tab in the key's turn, and after the refusal it makes the tab's cell
/// again, in its usual sync or in its one sync when it shows. They fail when a refusal leaves the pane on the screen
/// without its tab: a hold that still keeps the tab bar from its model, or a tab bar that comes back and does not
/// sync.
///
/// The clock and the store are those of `PaneCloseTabGoesWithItsPaneTests` (a manual 120 Hz clock, an offline store).
/// The test makes the one call of the tab bar's own job (`TabStripView.syncFromModel()`) itself, and it runs the work
/// that follows a frame's commit where the test says so (`Fixture.committed`).
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
            #expect(close.host.superview != nil && !close.host.isHiddenOrHasHiddenAncestor, "frame \(frame): the pane does not show")
            #expect(close.strip.cells[close.tab] != nil, "frame \(frame): the pane shows with an empty tab bar after the refusal")
            #expect(Set(close.strip.cells.keys) == Set(close.pane.stripModel.tabs.map(\.id)),
                    "frame \(frame): the tab bar's cells are not its model's tabs")
        }
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
}
