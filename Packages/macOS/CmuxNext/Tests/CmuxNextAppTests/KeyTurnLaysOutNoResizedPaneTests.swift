import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// RESIZE VIDEOS F1 part 2 (STATUS 6948; #32197 is part 1): a close's and a split's key turn draws the motion's first
/// frame (the lead frame, so no hole and no sliver shows), and on the base it laid every resized pane out there:
/// `layoutSubtreeIfNeeded` on each, then that layout through the Core Animation commit. In the suite's xctrace
/// profiles that synchronous layout and its commit are most of the 20-40 ms key turn, which misses a refresh at
/// 120 Hz. Chrome's model: the input turn changes the model and the compositor moves layers; layout runs once per
/// frame, at the frame's tick. So in the key turn a resized pane's host takes its first-frame rect and its content
/// keeps the size it has (pinned and clipped); its first layout at a new size runs at the first display tick, and
/// from there it lays out live every frame as before. A new pane (no content size yet) still lays out to show.
/// The test is the layout's clock (120 Hz); the display link never ticks.
@MainActor
@Suite(.closesItsWindows)
struct KeyTurnLaysOutNoResizedPaneTests {
    /// Pane content that counts its resizes.
    final class Content: NSView {
        var resizes = 0
        override func setFrameSize(_ newSize: NSSize) {
            if newSize != frame.size { resizes += 1 }
            super.setFrameSize(newSize)
        }
    }

    final class Panes: LayoutPaneContentProvider {
        var contents: [PaneID: Content] = [:]
        func makeContentView(for pane: PaneID) -> NSView {
            let content = Content()
            contents[pane] = content
            return content
        }
    }

    static let dt = 1.0 / 120

    final class Window {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init(_ layout: ScreenLayout, focus: PaneID) {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: focus)
            model.splitSizingOverride = .even
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            for _ in 0..<600 where root.advanceFrame(KeyTurnLaysOutNoResizedPaneTests.dt) {}
        }

        var screen: ScreenContentView { root.screenViews["s"]! }

        func show(_ layout: ScreenLayout) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: layout)])
            root.syncWithModel()
        }

        /// The panes whose hosts the key turn resized, with their content sizes before it.
        func sizes(_ panes: [PaneID]) -> [PaneID: CGSize] {
            Dictionary(uniqueKeysWithValues: panes.compactMap { pane in provider.contents[pane].map { (pane, $0.frame.size) } })
        }
    }

    static func columns(_ panes: [PaneID]) -> ScreenLayout {
        .columns(panes.map { LayoutColumn(id: ColumnID("c-\($0.rawValue)"), width: 1.0 / 3, root: .leaf($0)) })
    }

    /// Checks the key turn moved the hosts and resized no content, and the first tick lays the content out.
    static func expectNoLayoutInKeyTurn(_ app: Window, panes: [PaneID], before: [PaneID: CGSize], hostsBefore: [PaneID: CGSize],
                                        sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(app.screen.hasMotion, "fixture: the change springs", sourceLocation: sourceLocation)
        var resizedHosts = 0
        for pane in panes {
            let content = app.provider.contents[pane]!, host = app.root.context.hosts[pane]!
            if host.frame.size != hostsBefore[pane] { resizedHosts += 1 }
            #expect(content.frame.size == before[pane],
                    "\(pane): the key turn laid its content out at \(content.frame.size) (was \(before[pane]!)); its first layout belongs to the first tick",
                    sourceLocation: sourceLocation)
        }
        #expect(resizedHosts > 0, "fixture: the key turn's lead frame resized no host", sourceLocation: sourceLocation)
        let resizes = panes.map { app.provider.contents[$0]!.resizes }
        app.root.advanceFrame(dt)
        for (pane, count) in zip(panes, resizes) {
            let content = app.provider.contents[pane]!, host = app.root.context.hosts[pane]!
            #expect(content.resizes > count, "\(pane): the first tick did not lay its content out", sourceLocation: sourceLocation)
            #expect(content.frame.size == host.contentRect.size || host.isOnLayoutSpring,
                    "\(pane): after the first tick its content (\(content.frame.size)) does not fill its clip (\(host.contentRect.size))",
                    sourceLocation: sourceLocation)
        }
        for _ in 0..<600 where app.root.advanceFrame(dt) {}
        for pane in panes {
            let content = app.provider.contents[pane]!, host = app.root.context.hosts[pane]!
            #expect(content.frame.size == host.contentRect.size, "\(pane): at rest its content does not fill its clip", sourceLocation: sourceLocation)
        }
    }

    /// Cmd-W on the middle column: the two neighbours grow in the close's first frame without a layout in the key turn.
    @Test func aClosesKeyTurnLaysOutNoGrowingPane() {
        let app = Window(Self.columns(["p1", "p2", "p3"]), focus: "p2")
        defer { app.window.closeAfterTest() }
        let panes: [PaneID] = ["p1", "p3"]
        let before = app.sizes(panes)
        let hostsBefore = Dictionary(uniqueKeysWithValues: panes.map { ($0, app.root.context.hosts[$0]!.frame.size) })
        app.model.focus("p1", notify: false)
        app.show(Self.columns(["p1", "p3"]))
        Self.expectNoLayoutInKeyTurn(app, panes: panes, before: before, hostsBefore: hostsBefore)
    }

    /// Cmd-D on p2 of a pair: p1 and p2 shrink in the split's first frame without a layout in the key turn; the new
    /// pane (no content yet) lays out to show.
    @Test func aSplitsKeyTurnLaysOutNoShrinkingPane() {
        let pair: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
        let split: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                      b: .split("n", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))
        let app = Window(.splits(pair), focus: "p2")
        defer { app.window.closeAfterTest() }
        let panes: [PaneID] = ["p2"]
        let before = app.sizes(panes)
        let hostsBefore = Dictionary(uniqueKeysWithValues: panes.map { ($0, app.root.context.hosts[$0]!.frame.size) })
        _ = app.model.showSplitSizing(app.model.splitSizingChanges(splitting: "p2", axis: .horizontal))
        app.show(.splits(split))
        let created = app.provider.contents["p3"]
        #expect(created.map { $0.frame.width >= 1 } == true, "the new pane did not lay out to show in the key turn")
        Self.expectNoLayoutInKeyTurn(app, panes: panes, before: before, hostsBefore: hostsBefore)
    }
}
