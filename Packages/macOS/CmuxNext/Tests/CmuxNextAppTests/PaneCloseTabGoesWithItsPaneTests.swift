import AppKit
@testable import CmuxNextApp
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Cmd-W on a pane's last tab: the tab and its pane go in one frame.
///
/// What the screen must never show: the closing pane still at its place, with its content, and an empty tab bar
/// (only the new-tab button). A screen recording of the app showed that picture for one or two refreshes, then the
/// picture without the pane.
///
/// The test is the layout's clock (`DisplayLinkDriver.isManual`, 120 Hz steps); the daemon is an offline store. The
/// tab bar follows its model in a job of its own, between the key's turn and the frame tick: the test makes that
/// job's one call (`TabStripView.syncFromModel()`) itself, so it waits for nothing.
@Suite(.closesItsWindows)
@MainActor struct PaneCloseTabGoesWithItsPaneTests {
    typealias Fixture = ClosedPaneContentStaysUntilLandingTests.Fixture

    /// The most frame ticks the test steps before it says that the close never showed.
    static let frames = 8

    @Test(.timeLimit(.minutes(1)))
    func aClosingPaneShowsItsLastTabInEachFrameThatShowsThePane() async throws {
        let app = try await Fixture()
        defer { app.close() }
        // The columns that stay share the window after a close: the close changes a pane's size, so it shows at a
        // frame tick and not in the key's own turn.
        app.content.layoutModel.newColumnWidthModeOverride = .fitScreen
        app.content.applyCurrent()
        app.settle()

        let closing = try app.pane(2)
        let strip = closing.view.stripView
        let tabs = closing.stripModel.orderedTabs.map(\.id)
        try #require(tabs.count == 1, "SETUP: the pane has \(tabs.count) tabs, not 1")
        let tab = tabs[0]
        strip.syncFromModel()
        try #require(strip.isShownInWindow, "SETUP: the pane's tab bar does not count as shown in its window")
        try #require(strip.cells[tab] != nil, "SETUP: the tab bar does not show the pane's tab before the close")
        let host = try #require(app.root.context.hosts[closing.layoutPaneID], "SETUP: the pane has no host in the layout")
        try #require(host.superview != nil && !host.isHiddenOrHasHiddenAncestor, "SETUP: the pane does not show before the close")

        // The key's turn, as Cmd-W on the pane's last tab runs it.
        _ = try #require(closing.prepareClose(tabs), "SETUP: the close has no daemon tab")
        try #require(closing.stripModel.tabs.isEmpty, "SETUP: the key's turn left the tab in the tab bar's model")
        try #require(host.superview != nil && !host.isHidden,
                     "SETUP: the key's own turn hid the pane, so no frame shows the pane after the key")
        // Between the key's turn and the frame tick: the tab bar follows its model.
        strip.syncFromModel()
        #expect(strip.cells[tab] != nil, "before a frame tick the closing pane still shows, and its tab bar is empty")

        // Each frame tick until the one that hides the pane: while the pane shows, so does its tab.
        var bare: [Int] = []
        var hidden: Int?
        for frame in 1...Self.frames {
            _ = app.root.advanceFrame(ClosedPaneContentStaysUntilLandingTests.dt)
            if host.isHidden || host.superview == nil {
                hidden = frame
                break
            }
            strip.syncFromModel()
            if strip.cells[tab] == nil { bare.append(frame) }
        }
        _ = try #require(hidden, "SETUP: no frame of \(Self.frames) hid the closing pane")
        #expect(bare.isEmpty, "the closing pane shows with an empty tab bar in the frames \(bare) after the key")
    }
}
