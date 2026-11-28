import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A divider's double-click through the real handle views (https://github.com/manaflow-ai/cmux/issues/57175): the
/// screen hands the chain's laid-out size to the equalize, so a pane stack held at its minimum width leaves the other
/// panes even; a fourth click of a run evens again after a third one dragged; a row edge's double-click evens the rows.
@MainActor
@Suite(.closesItsWindows)
struct DividerDoubleClickViewTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Harness {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        var intents: [LayoutIntent] = []

        init(_ column: LayoutColumn, width: CGFloat = 1200, height: CGFloat = 800) {
            _ = NSApplication.shared
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([column]))], activeScreenID: "s",
                                focusedPane: column.root.panes[0])
            model.followsDesignMetrics = false
            var style = LayoutStyle()
            style.minimumPaneContentSize = CGSize(width: 200, height: 64)
            model.baseStyle = style
            model.acceptsRowOps = true
            root = LayoutRootView(model: model, contentProvider: provider)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            model.intentHandler = { [unowned self] in intents.append($0) }
        }

        var screen: ScreenContentView {
            get throws { try #require(root.screenViews["s"]) }
        }

        func handle(_ kind: DividerHandleView.Kind) throws -> DividerHandleView {
            try #require(try screen.dividerViews[kind], "no handle \(kind)")
        }

        func event(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }

        /// One click of a run (`clicks` is its click count) on the middle of `kind`'s handle; `drag` moves it first.
        func click(_ kind: DividerHandleView.Kind, clicks: Int, drag: CGFloat = 0) throws {
            let handle = try handle(kind)
            let point = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
            handle.mouseDown(with: event(.leftMouseDown, point, clicks: clicks))
            if drag != 0 {
                handle.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: point.x + drag, y: point.y), clicks: clicks))
            }
            handle.mouseUp(with: event(.leftMouseUp, CGPoint(x: point.x + drag, y: point.y), clicks: clicks))
            root.syncWithModel()
            root.layoutSubtreeIfNeeded()
        }

        func widths(_ panes: [PaneID]) throws -> [CGFloat] {
            let frames = try screen.baseGeometry.panes
            return panes.map { frames[$0]?.width ?? -1 }
        }
    }

    /// A | (B | X), X = C / (D | E | F) needing 3 x 200 + 2 dividers: more than a third of the column.
    static let clampedColumn = LayoutColumn(
        id: "col", width: 1,
        root: .split("outer", axis: .horizontal, ratio: 0.6, a: .leaf("a"),
                     b: .split("inner", axis: .horizontal, ratio: 0.5, a: .leaf("b"),
                               b: .split("x", axis: .vertical, ratio: 0.5, a: .leaf("c"),
                                         b: .split("def", axis: .horizontal, ratio: 0.3, a: .leaf("d"),
                                                   b: .split("ef", axis: .horizontal, ratio: 0.5, a: .leaf("e"), b: .leaf("f")))))))

    @Test(arguments: ["outer", "inner"] as [SplitID])
    func aDoubleClickEvensAroundAStackHeldAtItsMinimum(clicked: SplitID) throws {
        let harness = Harness(Self.clampedColumn)
        defer { harness.window.closeAfterTest() }
        try harness.click(.split(clicked), clicks: 1)
        try harness.click(.split(clicked), clicks: 2)
        let widths = try harness.widths(["a", "b", "c"])
        #expect(abs(widths[0] - widths[1]) <= 1, "A and B: \(widths)")
        #expect(widths[2] <= 3 * 200 + 2 * harness.model.style.dividerThickness + 1, "the stack at its minimum: \(widths)")
    }

    /// A fast third click drags (it is a press of its own), and the fourth evens the panes again.
    @Test func theFourthClickOfARunEvensAgain() throws {
        let column = LayoutColumn(id: "col", width: 1, root: .split("outer", axis: .horizontal, ratio: 0.5, a: .leaf("a"),
                                                                    b: .split("inner", axis: .horizontal, ratio: 0.5,
                                                                              a: .leaf("b"), b: .leaf("c"))))
        let harness = Harness(column, width: 1500)
        defer { harness.window.closeAfterTest() }
        try harness.click(.split("outer"), clicks: 1)
        try harness.click(.split("outer"), clicks: 2)
        var widths = try harness.widths(["a", "b", "c"])
        #expect((widths.max() ?? 0) - (widths.min() ?? 1) <= 1, "after the double-click: \(widths)")
        try harness.click(.split("outer"), clicks: 3, drag: 150)
        widths = try harness.widths(["a", "b", "c"])
        #expect((widths.max() ?? 0) - (widths.min() ?? 1) > 100, "the third click dragged: \(widths)")
        try harness.click(.split("outer"), clicks: 4)
        widths = try harness.widths(["a", "b", "c"])
        #expect((widths.max() ?? 0) - (widths.min() ?? 1) <= 1, "after the fourth click: \(widths)")
    }

    /// The line between two rows: its double-click sends the column's rows even and fitting (before, nothing).
    @Test func aRowEdgeDoubleClickEvensTheRows() throws {
        let rows = [LayoutRow(id: "r0", height: 700, root: .leaf("p0")), LayoutRow(id: "r1", height: 300, root: .leaf("p1"))]
        let column = LayoutColumn(id: "col", width: 1, root: .split("row-r1", axis: .vertical, ratio: 0.7, a: .leaf("p0"), b: .leaf("p1")),
                                  rows: rows)
        let harness = Harness(column)
        defer { harness.window.closeAfterTest() }
        try harness.click(.rowEdge("col", "r0"), clicks: 1)
        try harness.click(.rowEdge("col", "r0"), clicks: 2)
        let sent = harness.intents.compactMap { intent -> [Int]? in
            if case let .setRowHeights("col", heights, true) = intent { heights.map(\.height) } else { nil }
        }
        #expect(sent == [[500, 500]], "\(harness.intents)")
    }
}
