import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// Modifier keys held while dragging a divider or a column edge pick how the drag resizes
/// (plans/cmux-next/resize-modifiers.md): Option flips push and trade, Command applies the size to
/// every column (or evens the panes on both sides of a divider), Shift lands only on a snap, Control
/// moves at a quarter of the pointer's speed. A modifier pressed or let go mid-drag changes the mode
/// at once, and Escape cancels the drag back to where it began.
@MainActor
@Suite(.closesItsWindows)
struct DividerModifierDragTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Screen {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        var ended: [LayoutIntent] = []
        var cancelled = 0

        init(_ layout: ScreenLayout, focus: PaneID = "p1") {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: focus)
            root = LayoutRootView(model: model, contentProvider: provider)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            model.intentHandler = { [unowned self] intent in
                switch intent {
                case .setSplitRatio(_, _, _, .ended), .setColumnWidth(_, _, _, _, .ended): ended.append(intent)
                case .cancelGesture: cancelled += 1
                default: break
                }
            }
        }

        var screen: ScreenContentView { root.screenViews["s"]! }
        var layout: ScreenLayout { model.screens[0].layout }
        func ratio(_ split: SplitID) -> Double? { layout.ratio(of: split) }
        func width(_ column: ColumnID) -> Double? { layout.columns.first { $0.id == column }?.width }
        /// A strip column's drawn width in points for a stored width fraction.
        func points(_ fraction: Double) -> CGFloat {
            ColumnStripGeometry.pixelWidth(fraction: fraction, viewportWidth: screen.geometry.stripWidth, gap: screen.context.style.stripGap)
        }

        func handle(_ kind: DividerHandleView.Kind) throws -> DividerHandleView {
            try #require(screen.dividerViews[kind], "no handle \(kind)")
        }

        /// Presses `kind`'s handle at its center with `flags` held.
        func press(_ kind: DividerHandleView.Kind, flags: NSEvent.ModifierFlags = []) throws -> (DividerHandleView, CGPoint) {
            let view = try handle(kind)
            let from = screen.convert(CGPoint(x: view.frame.midX, y: view.frame.midY), to: nil)
            view.mouseDown(with: event(.leftMouseDown, from, flags))
            return (view, from)
        }

        /// Moves a pressed handle `dx` points right of where it was pressed, in two steps.
        func move(_ view: DividerHandleView, from: CGPoint, by dx: CGFloat, flags: NSEvent.ModifierFlags = []) {
            view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: from.x + dx / 2, y: from.y), flags))
            view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: from.x + dx, y: from.y), flags))
        }

        func release(_ view: DividerHandleView, at point: CGPoint, flags: NSEvent.ModifierFlags = []) {
            view.mouseUp(with: event(.leftMouseUp, point, flags))
        }

        /// A whole drag of `kind` by `dx` points with `flags` held throughout.
        func drag(_ kind: DividerHandleView.Kind, by dx: CGFloat, flags: NSEvent.ModifierFlags = []) throws {
            let (view, from) = try press(kind, flags: flags)
            move(view, from: from, by: dx, flags: flags)
            release(view, at: CGPoint(x: from.x + dx, y: from.y), flags: flags)
        }

        func flags(_ view: DividerHandleView, _ flags: NSEvent.ModifierFlags) {
            let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: "",
                                         charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!
            view.flagsChanged(with: event)
        }

        private func event(_ type: NSEvent.EventType, _ point: CGPoint, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
    }

    static func threeColumns(_ widths: [Double] = [0.4, 0.4, 0.4]) -> ScreenLayout {
        .columns([
            LayoutColumn(id: "c0", width: widths[0], root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))),
            LayoutColumn(id: "c1", width: widths[1], root: .leaf("p3")),
            LayoutColumn(id: "c2", width: widths[2], root: .leaf("p4")),
        ])
    }

    // MARK: Option

    @Test func optionDraggingASplitDividerGrowsItsColumnAndPushesTheColumnsAfterIt() throws {
        let screen = Screen(Self.threeColumns())
        defer { screen.window.closeAfterTest() }
        let divider = try #require(screen.screen.geometry.dividers.first { $0.id == "x" })
        let t = screen.screen.context.style.dividerThickness
        let rightPane = (divider.container.width - t) * 0.5
        let column = screen.points(0.4)

        try screen.drag(.split("x"), by: 60, flags: .option)

        // The column is 60 pt wider, the pane right of the divider keeps its width, the next
        // column keeps its own.
        let width = try #require(screen.width("c0"))
        #expect(abs(screen.points(width) - (column + 60)) < 1)
        let ratio = try #require(screen.ratio("x"))
        #expect(abs((divider.container.width + 60 - t) * (1 - ratio) - rightPane) < 1)
        #expect(screen.width("c1") == 0.4)
        #expect(screen.width("c2") == 0.4)
    }

    @Test func optionDraggingAColumnEdgeTradesWidthWithTheNextColumn() throws {
        let screen = Screen(Self.threeColumns())
        defer { screen.window.closeAfterTest() }
        let start = screen.points(0.4)

        try screen.drag(.columnEdge("c0"), by: 50, flags: .option)

        let first = try #require(screen.width("c0")), second = try #require(screen.width("c1"))
        #expect(abs(screen.points(first) - (start + 50)) < 1)
        #expect(abs(screen.points(second) - (start - 50)) < 1)
        #expect(screen.width("c2") == 0.4)
    }

    @Test func withoutAModifierAColumnEdgeResizesOnlyItsColumn() throws {
        let screen = Screen(Self.threeColumns())
        defer { screen.window.closeAfterTest() }
        try screen.drag(.columnEdge("c0"), by: 50)
        #expect(screen.width("c1") == 0.4)
        #expect(screen.width("c2") == 0.4)
    }

    // MARK: Command

    @Test func commandDraggingAColumnEdgeGivesEveryColumnThatWidth() throws {
        let screen = Screen(Self.threeColumns([0.4, 0.3, 0.6]))
        defer { screen.window.closeAfterTest() }
        try screen.drag(.columnEdge("c0"), by: 40, flags: .command)
        let first = try #require(screen.width("c0"))
        #expect(abs(screen.points(first) - (screen.points(0.4) + 40)) < 1)
        #expect(screen.width("c1") == first)
        #expect(screen.width("c2") == first)
    }

    @Test func commandDraggingADividerEvensThePanesOnItsFarSide() throws {
        // p1 | (p2 | p3) with p2 and p3 uneven: Command evens them while p1 follows the pointer.
        let tree: SplitNode = .split("x", axis: .horizontal, ratio: 0.4, a: .leaf("p1"),
                                     b: .split("y", axis: .horizontal, ratio: 0.2, a: .leaf("p2"), b: .leaf("p3")))
        let screen = Screen(.splits(tree))
        defer { screen.window.closeAfterTest() }
        let divider = try #require(screen.screen.geometry.dividers.first { $0.id == "x" })
        let available = divider.container.width - screen.screen.context.style.dividerThickness
        try screen.drag(.split("x"), by: 30, flags: .command)
        #expect(screen.ratio("y") == 0.5)
        let ratio = try #require(screen.ratio("x"))
        #expect(abs(CGFloat(ratio - 0.4) * available - 30) < 1)
    }

    // MARK: Shift and Control

    @Test func shiftLandsADividerOnTheNearestSnapEvenFarFromIt() throws {
        let screen = Screen(.splits(.split("x", axis: .horizontal, ratio: 0.3, a: .leaf("p1"), b: .leaf("p2"))))
        defer { screen.window.closeAfterTest() }
        // 0.3 + 230 pt of 1600 is about 0.44: free without Shift (8 pt snap reach), a half with it.
        try screen.drag(.split("x"), by: 230, flags: .shift)
        #expect(screen.ratio("x") == 0.5)
    }

    @Test func shiftLandsAColumnEdgeOnAPresetWidth() throws {
        let screen = Screen(Self.threeColumns())
        defer { screen.window.closeAfterTest() }
        try screen.drag(.columnEdge("c0"), by: 60, flags: .shift)
        #expect(screen.width("c0") == 0.5)
    }

    @Test func controlMovesADividerAtAQuarterOfThePointersSpeed() throws {
        let screen = Screen(.splits(.split("x", axis: .horizontal, ratio: 0.3, a: .leaf("p1"), b: .leaf("p2"))))
        defer { screen.window.closeAfterTest() }
        let divider = try #require(screen.screen.geometry.dividers.first { $0.id == "x" })
        let available = divider.container.width - screen.screen.context.style.dividerThickness
        try screen.drag(.split("x"), by: 80, flags: .control)
        let ratio = try #require(screen.ratio("x"))
        #expect(abs(CGFloat(ratio - 0.3) * available - 20) < 1)
    }

    // MARK: Live changes and cancel

    @Test func lettingGoOfCommandMidDragPutsTheOtherColumnsBack() throws {
        let screen = Screen(Self.threeColumns([0.4, 0.3, 0.6]))
        defer { screen.window.closeAfterTest() }
        let (view, from) = try screen.press(.columnEdge("c0"), flags: .command)
        screen.move(view, from: from, by: 40, flags: .command)
        #expect(screen.width("c1") == screen.width("c0"))
        screen.flags(view, [])
        #expect(screen.width("c1") == 0.3)
        #expect(screen.width("c2") == 0.6)
        screen.release(view, at: CGPoint(x: from.x + 40, y: from.y))
        #expect(screen.width("c1") == 0.3)
        // One ended width goes to the daemon: the dragged column's.
        #expect(screen.ended.count == 1)
    }

    @Test func pressingOptionMidDragSwitchesToPushWithoutMovingTheDivider() throws {
        let screen = Screen(Self.threeColumns())
        defer { screen.window.closeAfterTest() }
        let divider = try #require(screen.screen.geometry.dividers.first { $0.id == "x" })
        let t = screen.screen.context.style.dividerThickness
        let column = screen.points(0.4)
        /// The left pane's width: the split's room grows with its column.
        func leftPane() -> CGFloat {
            let grown = screen.points(screen.width("c0") ?? 0.4) - column
            return CGFloat(screen.ratio("x") ?? 0) * (divider.container.width + grown - t)
        }
        let (view, from) = try screen.press(.split("x"))
        screen.move(view, from: from, by: 30)
        let before = leftPane()
        screen.flags(view, .option)
        // The pointer did not move: the divider stays under it, the column takes the width now.
        #expect(abs(leftPane() - before) < 1)
        screen.release(view, at: CGPoint(x: from.x + 30, y: from.y), flags: .option)
        #expect(abs(leftPane() - before) < 1)
    }

    @Test func escapeCancelsADragAndRestoresTheStart() throws {
        let screen = Screen(Self.threeColumns())
        defer { screen.window.closeAfterTest() }
        let (view, from) = try screen.press(.split("x"), flags: .option)
        screen.move(view, from: from, by: 80, flags: .option)
        #expect(screen.width("c0") != 0.4)
        view.cancelOperation(nil)
        #expect(screen.ratio("x") == 0.5)
        #expect(screen.width("c0") == 0.4)
        screen.release(view, at: CGPoint(x: from.x + 80, y: from.y), flags: .option)
        #expect(screen.ratio("x") == 0.5)
        #expect(screen.ended.isEmpty)
        #expect(screen.cancelled == 1)
    }
}
