import AppKit
import CmuxNextBridge
@testable import CmuxNextLayout
import CmuxNextWakeups
import Testing

/// Panes as small as drawing allows (Lawrence 2026-10-28: "minimum width/height of a pane needs to be a lot smaller
/// than it currently is", then "we should let panes be even smaller, idk what use cases people might have, but we
/// should support it"; handoff pane-min.md, repeat-runoff.md part 2). With the default minimum a pane keeps one
/// terminal cell of content (8 x 16 pt at 13 pt) and, below that, folds into a bar as thick as a divider's hit
/// area. A divider, a key or a small window can take a pane there and back; no two panes ever overlap.
@MainActor @Suite(.serialized) struct PaneMinimumSizeTests {
    static let pair: SplitNode = .split(SplitID("x"), axis: .horizontal, ratio: 0.5, a: .leaf(PaneID("p1")), b: .leaf(PaneID("p2")))
    static let stack: SplitNode = .split(SplitID("y"), axis: .vertical, ratio: 0.5, a: .leaf(PaneID("p1")), b: .leaf(PaneID("p2")))

    /// The default floor is one cell of content, not 200 x 64 pt below the tab strip.
    @Test func theDefaultFloorIsOneTerminalCell() {
        let style = LayoutStyle()
        #expect(style.minimumPaneSize.width <= 8 + 2 * style.panePadding + 0.5, "\(style.minimumPaneSize)")
        #expect(style.minimumPaneSize.height <= 16 + 2 * style.panePadding + 0.5, "\(style.minimumPaneSize)")
    }

    /// A divider placed 20 pt from the container's edge leaves that pane 20 pt wide (two terminal columns),
    /// and at the edge the pane is thinner than one cell: folded, not held at a floor of 200 pt.
    @Test func theGeometryHonorsSmallRatios() throws {
        let style = LayoutStyle()
        let container = CGRect(x: 0, y: 0, width: 800, height: 600)
        let twenty = (20 + style.dividerThickness / 2) / container.width
        let at20 = SplitGeometry.layout(Self.pair.settingRatio(Double(twenty), for: SplitID("x")), in: container, style: style)
        let p1 = try #require(at20.panes[PaneID("p1")])
        #expect(abs(p1.width - 20) <= 1, "p1 is \(p1.width) pt wide")
        let edge = SplitGeometry.layout(Self.pair.settingRatio(0.001, for: SplitID("x")), in: container, style: style)
        let folded = try #require(edge.panes[PaneID("p1")])
        #expect(folded.width <= style.collapsedPaneExtent + 0.5, "a pane at the edge collapses: \(folded.width) pt")
        let rest = try #require(edge.panes[PaneID("p2")])
        #expect(abs(folded.maxX + style.dividerThickness - rest.minX) < 0.5 && abs(rest.maxX - container.maxX) < 0.5, "\(folded) \(rest)")
    }

    /// The same for heights: a pane one terminal row tall, with no tab strip above it.
    @Test func aPaneCanBeOneRowTall() throws {
        let style = LayoutStyle()
        let container = CGRect(x: 0, y: 0, width: 800, height: 600)
        let ratio = (18 + style.dividerThickness / 2) / container.height
        let laid = SplitGeometry.layout(Self.stack.settingRatio(Double(ratio), for: SplitID("y")), in: container, style: style)
        let p1 = try #require(laid.panes[PaneID("p1")])
        #expect(abs(p1.height - 18) <= 1, "p1 is \(p1.height) pt tall")
    }

    /// Ctrl-Cmd-Left from 5% moves the divider on to the edge, where the pane folds; Ctrl-Cmd-Right brings it back.
    @Test func theKeyboardResizesToTheEdgeAndBack() throws {
        let layout = ScreenLayout.splits(Self.pair.settingRatio(0.05, for: SplitID("x")))
        let change = try #require(PaneResize.change(for: PaneID("p1"), direction: .left, in: layout), "the key moves the divider past 5%")
        guard case let .splitRatio(split, ratio) = change else {
            Issue.record("expected a split ratio, got \(change)")
            return
        }
        #expect(split == SplitID("x") && ratio < 0.01, "\(change)")
        let folded = layout.settingRatio(ratio, for: split)
        let style = LayoutStyle()
        let frames = SplitGeometry.layout(try #require(folded.tree(containing: SplitID("x"))), in: CGRect(x: 0, y: 0, width: 1200, height: 800), style: style)
        #expect(try #require(frames.panes[PaneID("p1")]).width <= style.collapsedPaneExtent + 0.5)
        let back = try #require(PaneResize.change(for: PaneID("p1"), direction: .right, in: folded))
        guard case let .splitRatio(_, grown) = back else {
            Issue.record("expected a split ratio, got \(back)")
            return
        }
        #expect(grown > ratio, "\(back)")
    }

    /// Sixteen panes side by side fit a 400 pt window: each split has room, every pane is at least one cell
    /// wide at even shares, and none overlaps another or leaves the window.
    @Test func manySplitsFitASmallWindow() throws {
        let style = LayoutStyle()
        let viewport = CGSize(width: 400, height: 300)
        var tree = SplitNode.leaf(PaneID("p0"))
        for index in 1..<16 {
            let last = PaneID("p\(index - 1)")
            let placement = SplitRoom.placement(splitting: last, axis: .horizontal, in: .splits(tree), viewport: viewport, style: style)
            try #require(placement == .split, "split \(index) refused: \(placement)")
            tree = tree.replacingLeaf(last) { .split(SplitID("s\(index)"), axis: .horizontal, ratio: 0.5, a: $0, b: .leaf(PaneID("p\(index)"))) }
        }
        for change in EvenSplitRatios.changes(equalizing: tree, axis: .horizontal) { tree = tree.settingRatio(change.ratio, for: change.split) }
        let frames = SplitGeometry.layout(tree, in: CGRect(origin: .zero, size: viewport), style: style).panes
        #expect(frames.count == 16)
        for (pane, frame) in frames {
            #expect(frame.width >= 8 - 0.5, "\(pane) is \(frame.width) pt wide")
        }
        Self.expectTiled(frames, in: CGRect(origin: .zero, size: viewport))
    }

    /// A window narrower than every pane's floor together: the panes share it, none overlaps another or leaves it.
    @Test func aWindowBelowTheSumOfTheFloorsNeverOverlapsPanes() {
        let style = LayoutStyle()
        var tree = SplitNode.leaf(PaneID("p0"))
        for index in 1..<6 {
            tree = tree.replacingLeaf(PaneID("p\(index - 1)")) { .split(SplitID("s\(index)"), axis: .horizontal, ratio: 0.5, a: $0, b: .leaf(PaneID("p\(index)"))) }
        }
        for width in [40.0, 20, 9, 3] as [CGFloat] {
            let rect = CGRect(x: 0, y: 0, width: width, height: 100)
            Self.expectTiled(SplitGeometry.layout(tree, in: rect, style: style).panes, in: rect)
        }
    }

    /// Divider drags through the real view: dragged to the window's edge the left pane folds into a bar; dragged
    /// back it is as wide as the pointer says.
    @Test func aDividerDragFoldsThePaneAndBringsItBack() throws {
        let harness = try DragHarness()
        defer { harness.close() }
        harness.drag(toX: 2)
        let folded = try harness.frame(of: PaneID("p1"))
        #expect(folded.width <= LayoutStyle().collapsedPaneExtent + 0.5 && folded.width > 0, "dragged to the edge the pane collapses: \(folded.width) pt")
        harness.drag(toX: 300)
        let back = try harness.frame(of: PaneID("p1"))
        #expect(abs(back.width - 300) <= 2, "dragged back the pane is 300 pt wide: \(back.width) pt")
        harness.drag(toX: 30)
        let small = try harness.frame(of: PaneID("p1"))
        #expect(abs(small.width - 30) <= 2, "a 30 pt pane stays 30 pt (a terminal of three columns): \(small.width) pt")
    }

    /// Every frame inside `rect`, and no two frames overlap.
    static func expectTiled(_ frames: [PaneID: CGRect], in rect: CGRect) {
        let sorted = frames.sorted { $0.value.minX < $1.value.minX }
        for (pane, frame) in sorted {
            #expect(frame.minX >= rect.minX - 0.5 && frame.maxX <= rect.maxX + 0.5, "\(pane) \(frame) leaves \(rect)")
            #expect(frame.width > 0 && frame.height > 0, "\(pane) \(frame): every pane keeps some room")
        }
        for (first, second) in zip(sorted, sorted.dropFirst()) {
            #expect(first.value.maxX <= second.value.minX + 0.5, "\(first.key) \(first.value) overlaps \(second.key) \(second.value)")
        }
    }

    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// p1 | p2 in a 1200 x 800 window, laid out at rest (Reduce Motion).
    final class DragHarness {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init() throws {
            _ = NSApplication.shared
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(PaneMinimumSizeTests.pair))],
                                activeScreenID: "s", focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.setDragInput(frames: nil, resampler: { nil })
            root.context.reduceMotionOverride = true
        }

        var screen: ScreenContentView {
            get throws { try #require(root.screenViews["s"]) }
        }

        var handle: DividerHandleView {
            get throws { try #require(root.screenViews["s"]?.dividerViews[.split("x")]) }
        }

        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        /// Presses the divider where it is, drags it to window x `x` and lets go.
        func drag(toX x: CGFloat) {
            guard let handle = try? handle else {
                Issue.record("no divider handle")
                return
            }
            let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
            let end = CGPoint(x: x, y: start.y)
            handle.mouseDown(with: event(.leftMouseDown, start))
            handle.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: (start.x + end.x) / 2, y: start.y)))
            handle.mouseDragged(with: event(.leftMouseDragged, end))
            handle.mouseUp(with: event(.leftMouseUp, end))
            root.layoutSubtreeIfNeeded()
        }

        /// `pane`'s frame at rest: the screen's geometry for the model's ratio.
        func frame(of pane: PaneID) throws -> CGRect {
            try #require(try screen.geometry.panes[pane])
        }

        func close() { window.close() }
    }
}
