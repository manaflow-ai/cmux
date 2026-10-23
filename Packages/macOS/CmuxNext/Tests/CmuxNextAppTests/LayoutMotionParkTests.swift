import AppKit
@testable import CmuxNextLayout
import Testing

/// Layout motion observers (``LayoutRootView/observeLayoutMotion(_:)``) hear a motion end when
/// its root parks or hides mid-spring (review 1 of PL-motion-core).
@MainActor
struct LayoutMotionParkTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Moves {
        var heard: [Bool] = []
    }

    /// A workspace parked during a split's spring: the motion ends where it was going, and the
    /// layout motion observers hear it (a Chromium page leaves motion mode), not at the next motion.
    @Test func parkingMidSpringTellsTheMotionObserversItEnded() throws {
        let split: SplitNode = .split("h", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p1"))
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(split))], activeScreenID: "s",
                                focusedPane: "p1")
        let root = LayoutRootView(model: model, contentProvider: Panes())
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        let moves = Moves()
        let observation = root.observeLayoutMotion { moves.heard.append($0) }

        // p2 closes: p1 springs over the whole screen.
        model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("p1")))])
        root.syncWithModel()
        #expect(root.screenViews["s"]?.hasMotion == true)
        #expect(root.isLayoutInMotion)
        #expect(moves.heard == [true])

        root.isHidden = true
        #expect(!root.isLayoutInMotion, "the parked root still reports a motion")
        #expect(moves.heard == [true, false], "the motion observers never heard the parked motion end")
        withExtendedLifetime(observation) {}
    }
}
