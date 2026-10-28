import AppKit
@testable import CmuxNextLayout
import CmuxNextWakeups
import Testing

/// p03-rendering-096 (plans/cmux-next/chrome-parity/p03-rendering.md R6), screens of one workspace: the
/// screen switched away from hides and stays in the window, so a switch back moves no view into it. Its
/// layout waits for the show (`ScreenContentView.needsReconcileOnShow`, HiddenScreenResizeTests).
@MainActor
@Suite(.serialized) struct HiddenScreenStaysInWindowTests {
    /// A pane's content: counts its window moves.
    final class Probe: NSView {
        private(set) var moves = 0
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            moves += 1
        }
    }

    final class Panes: LayoutPaneContentProvider {
        var probes: [PaneID: Probe] = [:]
        func makeContentView(for pane: PaneID) -> NSView {
            let probe = Probe()
            probes[pane] = probe
            return probe
        }
    }

    final class Fixture {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        /// Two screens of one pane each, the first shown, no motion (each switch lands in its turn).
        init() {
            let screens = [
                LayoutScreen(id: "s1", name: "one", layout: .columns([LayoutColumn(id: "c1", width: 1, root: .leaf("p1"))])),
                LayoutScreen(id: "s2", name: "two", layout: .columns([LayoutColumn(id: "c2", width: 1, root: .leaf("p2"))])),
            ]
            model = LayoutModel(screens: screens, activeScreenID: "s1", focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            root.context.reduceMotionOverride = true
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
        }

        func select(_ id: ScreenID) {
            model.selectScreen(id)
            root.syncWithModel()
            root.layoutSubtreeIfNeeded()
            for _ in 0..<600 where root.advanceFrame(1.0 / 120) {}
        }

        func screen(_ id: ScreenID) -> ScreenContentView { root.screenViews[id]! }
    }

    @Test func switchingBackToAHiddenScreenMovesNoViewIntoTheWindow() throws {
        let fixture = Fixture()
        defer { fixture.window.close() }
        fixture.select("s2")
        fixture.select("s1")
        let probes = try ["p1", "p2"].map { try #require(fixture.provider.probes[PaneID(rawValue: $0)]) }
        let entered = probes.map(\.moves)

        for id in ["s2", "s1", "s2", "s1"] as [ScreenID] {
            fixture.select(id)
            let other: ScreenID = id == "s1" ? "s2" : "s1"
            #expect(!fixture.screen(id).isHidden && fixture.screen(other).isHidden, "the screen switched away from hides")
            #expect(fixture.screen(other).window === fixture.window, "a hidden screen stays in the window")
        }
        let moved = zip(probes.map(\.moves), entered).map { $0 - $1 }
        #expect(moved == [0, 0], "screen switches moved pane content into or out of the window: \(moved)")
    }
}
