import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// Terminals resize at the start of a Cmd-D / Cmd-W, not after the spring (Lawrence 2026-10-23): when a split
/// starts, each pane it resizes tells its content the size it will rest at, once, in the first motion frame,
/// and the final size it gives (`bounds + sizeChange`) is the size the content has once the spring landed.
@MainActor
@Suite(.closesItsWindows) struct PaneMotionFinalSizeTests {
    /// A terminal-like leaf under a fixed 30 pt header, as a pane's tab strip sits over its terminal.
    final class Leaf: NSView, PaneMotionTargeting {
        var announced: [CGSize] = []
        func paneMotionWillRest(sizeChange: CGSize) -> PaneMotionAnchor {
            announced.append(CGSize(width: bounds.width + sizeChange.width, height: bounds.height + sizeChange.height))
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

    @Test func aSplitTellsEachResizedPaneItsFinalSizeOnceAtTheStart() async throws {
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
        model.apply(screens: PaneMotionBench.split(2, 1, axis: .horizontal))
        root.syncWithModel()
        var frames = 0
        var announcedByFirstFrame = 0
        while root.advanceFrame(1.0 / 120), frames < 240 {
            root.layoutSubtreeIfNeeded()
            frames += 1
            if frames == 1 { announcedByFirstFrame = before.announced.count }
        }
        root.layoutSubtreeIfNeeded()
        #expect(frames > 3, "the split sprang")
        #expect(announcedByFirstFrame == 1, "the split pane heard its final size \(announcedByFirstFrame) times by the first frame")
        #expect(before.announced.count == 1, "announced \(before.announced.count) times over the spring")
        let final = before.bounds.size
        let told = try #require(before.announced.first)
        #expect(abs(told.width - final.width) < 1 && abs(told.height - final.height) < 1, "told \(told), landed at \(final)")
    }

    /// Reduce Motion turned on while a split springs: the next frame shows the final layout and no more
    /// frames run (PL-burst finding).
    @Test func reduceMotionTurnedOnMidSpringLandsInTheNextFrame() throws {
        let model = LayoutModel(screens: PaneMotionBench.grid(2, 1), activeScreenID: "s", focusedPane: PaneID("p0-0"))
        let root = LayoutRootView(model: model, contentProvider: Panes())
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        model.apply(screens: PaneMotionBench.split(2, 1, axis: .horizontal))
        root.syncWithModel()
        for _ in 0..<3 { _ = root.advanceFrame(1.0 / 120) }
        let screen = try #require(root.screenViews.values.first)
        #expect(screen.hasMotion, "the split was not springing")
        root.context.reduceMotionOverride = true
        #expect(!root.advanceFrame(1.0 / 120), "frames go on after Reduce Motion turned on")
        #expect(!screen.hasMotion, "a pane is still between its start and its rest")
    }
}
