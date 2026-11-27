import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-11-07 ("this ui is problematic, im trying to drag tab from tabbar around"): a dragged tab must
/// feel like Chrome's and Safari's. The tab itself lifts and follows the pointer along its bar, a lone tab too
/// (it stayed stuck in its slot while the pointer moved on, then the ghost flew in from there once the pointer
/// left the bar); the + stays after the slots; back over a bar the tab sits in the opened gap inside the bar's
/// tabs (it poked out over the sidebar); and no bare caret stands by the gap. Real window, real strip, real
/// drag session, driven with mouse events.
@MainActor @Suite(.serialized, .closesItsWindows,
                 .enabled(if: !NSScreen.screens.isEmpty || ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1",
                          "the drag tests need a display"))
struct TabDragFollowsPointerTests {
    /// A window whose shown workspace has one pane with `tabCount` tabs, the first selected.
    static func fixture(tabCount: Int) async throws -> SidebarMultiViewWindowTests.Fixture {
        _ = NSApplication.shared
        let keys = ["k0", "k2"]
        var tree = SidebarMultiViewWindowTests.Fixture.tree(keys)
        for index in tree.workspaces.indices {
            let id = UInt64(index + 1)
            let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: (0..<(index == 0 ? tabCount : 1)).map { t in
                TabSnapshot(surface: SurfaceID(rawValue: id * 10 + UInt64(t)), title: t == 0 ? "Claude Code" : "Tab \(t)")
            })
            tree.workspaces[index].screens = [ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(pane.id), panes: [pane])]
        }
        return try await SidebarMultiViewWindowTests.Fixture(keys: keys, tree: tree)
    }

    @Test(arguments: [1, 3])
    func theLiftedTabFollowsThePointerAlongItsBar(tabCount: Int) async throws {
        let f = try await Self.fixture(tabCount: tabCount)
        defer { f.close() }
        let source = try #require(f.controller.content?.panes.values.first)
        let strip = source.view.stripView
        let id = CmuxNextTabs.TabID(try #require(source.pane.tabs.first).id)
        let cell = try #require(strip.cells[id])
        let startFrame = strip.tabsClip.convert(cell.frame, to: nil)
        let plusBefore = strip.newTabButton.frame
        let start = NSPoint(x: startFrame.midX, y: startFrame.midY)
        // 500 pt along the bar: past the last of 3 tabs, still inside the bar (it is ~950 pt wide).
        let travel: CGFloat = 500
        try #require(strip.convert(strip.bounds, to: nil).maxX > startFrame.maxX + travel, "the bar is too narrow for the drag")
        strip.mouseDown(with: try f.event(.leftMouseDown, at: start))
        for step in 1...20 {
            strip.mouseDragged(with: try f.event(.leftMouseDragged, at: NSPoint(x: start.x + travel * CGFloat(step) / 20, y: start.y)))
            f.frame()
        }
        try #require(strip.drag != nil, "the drag left the bar")
        let lifted = strip.tabsClip.convert(cell.frame, to: nil)
        #expect(abs(lifted.minX - (startFrame.minX + travel)) < 1,
                "\(tabCount) tab(s): the lifted tab is at x \(lifted.minX), not under the pointer at \(startFrame.minX + travel)")
        if tabCount == 1 {
            #expect(strip.newTabButton.frame == plusBefore, "the + followed the lifted tab: \(plusBefore) -> \(strip.newTabButton.frame)")
        }
        strip.mouseUp(with: try f.event(.leftMouseUp, at: NSPoint(x: start.x + travel, y: start.y)))
        f.frame()
    }

    @Test func backOverItsBarTheTabSitsInTheGapInsideTheBar() async throws {
        let f = try await Self.fixture(tabCount: 3)
        defer { f.close() }
        let window = try #require(f.controller.window)
        let source = try #require(f.controller.content?.panes.values.first)
        let strip = source.view.stripView
        let id = CmuxNextTabs.TabID(source.pane.tabs[1].id)
        let cell = try #require(strip.cells[id])
        let cellFrame = strip.tabsClip.convert(cell.frame, to: nil)
        let tabs = strip.tabsClip.convert(strip.tabsClip.bounds, to: nil)
        let start = NSPoint(x: cellFrame.midX, y: cellFrame.midY)
        strip.mouseDown(with: try f.event(.leftMouseDown, at: start))
        let session = f.services.dragSession
        // Down out of the bar (the session takes the tab over), then back onto the bar's first slot.
        var path: [NSPoint] = []
        for step in 1...10 {
            path.append(NSPoint(x: start.x, y: start.y - 12 * CGFloat(step)))
        }
        let back = tabs.minX + 4 - start.x
        for step in 1...10 {
            let t = CGFloat(step) / 10
            path.append(NSPoint(x: start.x + back * t, y: start.y - 120 + 120 * t))
        }
        for point in path {
            let event = try f.event(.leftMouseDragged, at: point)
            if session.drag != nil { _ = session.handle(event) } else { strip.mouseDragged(with: event) }
            f.frame()
        }
        let drag = try #require(session.drag, "the tab never left its bar")
        guard case .inline(let slot) = drag.presentation else {
            Issue.record("over its bar the tab is not inline: \(drag.presentation), winner \(String(describing: drag.winner?.proposal))")
            return
        }
        drag.motion.snap()
        let ghost = drag.ghost.layout(drag.motion)
        let shown = ghost.onScreen(ghost.tab)
        let span = window.convertToScreen(tabs)
        #expect(shown.minX >= span.minX - 0.5, "the tab pokes out of its bar's tabs: x \(shown.minX), tabs start at \(span.minX)")
        #expect(abs(shown.minY - slot.minY) < 0.5 && abs(shown.height - slot.height) < 0.5,
                "the tab is not on the bar's row: \(shown), slot \(slot)")
        let layout = try #require(f.controller.content?.layoutView)
        #expect(!layout.highlight.isShowing, "a drop overlay (the caret) shows by the gap: \(layout.highlight.destinationRect)")
        session.finish(commit: false)
        session.finishLanding()
        f.frame()
    }
}
