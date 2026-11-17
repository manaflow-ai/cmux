import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A pane spring tells each pane it resizes the size its content will rest at, once, when the spring starts, and the
/// final size it gives (`bounds + sizeChange`) is the size the content has once the spring landed: a terminal sends
/// its final grid then, not at the landing. A ratio or a width change springs (an equalize, a width preset, another
/// client's divider drag). A split, a close and a zoom do not: each is one commit with no rest notice, and the frame
/// that shows it gives each content its final size (`PaneLayoutCommitTests`, `TerminalPaneMotionFinalGridTests`).
@MainActor
@Suite(.closesItsWindows) struct PaneMotionFinalSizeTests {
    /// A terminal-like leaf under a fixed 30 pt header, as a pane's tab strip sits over its terminal.
    final class Leaf: NSView, PaneMotionTargeting {
        var announced: [CGSize] = []
        /// The size it had when it heard each rest.
        var heardAt: [CGSize] = []
        func paneMotionWillRest(sizeChange: CGSize) -> PaneMotionAnchor {
            announced.append(CGSize(width: bounds.width + sizeChange.width, height: bounds.height + sizeChange.height))
            heardAt.append(bounds.size)
            return .top
        }
    }

    final class Panes: LayoutPaneContentProvider {
        var leaves: [PaneID: Leaf] = [:]
        func makeContentView(for pane: PaneID) -> NSView {
            let container = NSView()
            let leaf = Leaf()
            leaf.autoresizingMask = [.width, .height]
            container.addSubview(leaf)
            container.postsFrameChangedNotifications = false
            leaf.frame = CGRect(x: 0, y: 30, width: 100, height: 70)
            container.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
            leaves[pane] = leaf
            return container
        }
    }

    /// The grid's two columns with the first one narrower (a width preset): the same panes and columns, so the frames
    /// spring. The first column's pane changes size; the second one's only moves.
    static var narrowed: [LayoutScreen] {
        [LayoutScreen(id: "s", name: "s", layout: .columns([
            PaneMotionBench.column(0, rows: 1, width: 0.35), PaneMotionBench.column(1, rows: 1, width: 0.5),
        ]))]
    }

    /// The first column narrows on a spring: its pane hears its final size one time, by the spring's first frame, and
    /// that size is the size its content has when the spring lands.
    @Test func aWidthSpringTellsEachResizedPaneItsFinalSizeOnceAtTheStart() async throws {
        let provider = Panes()
        let model = LayoutModel(screens: PaneMotionBench.grid(2, 1), activeScreenID: "s", focusedPane: PaneID("p0-0"))
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        let before = try #require(provider.leaves[PaneID("p0-0")])
        before.announced.removeAll()
        model.apply(screens: Self.narrowed)
        root.syncWithModel()
        var frames = 0
        var announcedByFirstFrame = 0
        while root.advanceFrame(1.0 / 120), frames < 240 {
            root.layoutSubtreeIfNeeded()
            frames += 1
            if frames == 1 { announcedByFirstFrame = before.announced.count }
        }
        root.layoutSubtreeIfNeeded()
        #expect(frames > 3, "the width change sprang")
        #expect(announcedByFirstFrame == 1, "the resized pane heard its final size \(announcedByFirstFrame) times by the first frame")
        #expect(before.announced.count == 1, "announced \(before.announced.count) times over the spring")
        let final = before.bounds.size
        let told = try #require(before.announced.first)
        #expect(abs(told.width - final.width) < 1 && abs(told.height - final.height) < 1, "told \(told), landed at \(final)")
    }

    /// The content hears its rest before the spring's first frame lays it out (#37755). A change whose presentation waits
    /// for the next frame tick (a frame's input, `LayoutViewContext.holdsPresentations`) is first presented by a stepped
    /// frame, which also resizes the pane. A Chromium page whose window holds the keys stays attached through the motion;
    /// it decides that, and lays itself out at its rest, when it hears the rest. Told after that frame's layout, its window
    /// had already taken the frame's size (one resize the WindowServer makes and Chromium lays out at, before the motion's
    /// own), and a terminal had already laid out a grid it leaves.
    @Test func theContentHearsItsRestBeforeTheSpringsFirstFrameLaysItOut() throws {
        let provider = Panes()
        let model = LayoutModel(screens: PaneMotionBench.grid(2, 1), activeScreenID: "s", focusedPane: PaneID("p0-0"))
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        let leaf = try #require(provider.leaves[PaneID("p0-0")])
        let start = leaf.bounds.size
        leaf.announced.removeAll()
        leaf.heardAt.removeAll()
        // The change's presentation waits for the frame tick, as a frame's input holds it.
        root.context.holdsPresentations = true
        model.apply(screens: Self.narrowed)
        root.syncWithModel()
        root.context.holdsPresentations = false
        try #require(leaf.heardAt.isEmpty && leaf.bounds.size == start, "SETUP: the change presented in its own turn")
        #expect(root.advanceFrame(1.0 / 120), "the width change did not spring")
        root.layoutSubtreeIfNeeded()
        try #require(leaf.heardAt.count == 1, "the resized pane heard its rest \(leaf.heardAt.count) times by the first frame")
        #expect(leaf.heardAt.first == start, "the first frame laid the content out at \(leaf.heardAt.first ?? .zero) before it heard its rest (start \(start))")
    }

    /// Reduce Motion turned on while a pane spring runs (a column's width on its way): the next frame shows the final
    /// layout and no more frames run (PL-burst finding).
    @Test func reduceMotionTurnedOnMidSpringLandsInTheNextFrame() throws {
        let model = LayoutModel(screens: PaneMotionBench.grid(2, 1), activeScreenID: "s", focusedPane: PaneID("p0-0"))
        let root = LayoutRootView(model: model, contentProvider: Panes())
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        model.apply(screens: Self.narrowed)
        root.syncWithModel()
        for _ in 0..<3 { _ = root.advanceFrame(1.0 / 120) }
        let screen = try #require(root.screenViews.values.first)
        #expect(screen.hasMotion, "the width change was not springing")
        root.context.reduceMotionOverride = true
        #expect(!root.advanceFrame(1.0 / 120), "frames go on after Reduce Motion turned on")
        #expect(!screen.hasMotion, "a pane is still between its start and its rest")
    }
}
