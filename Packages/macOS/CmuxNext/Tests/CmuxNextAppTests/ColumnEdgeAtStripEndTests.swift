import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// https://github.com/manaflow-ai/cmux/issues/55403: the edge between a full-width agent chat column and the column
/// opened beside it (a chat over a New Tab page) did not drag. The press reached the divider (its band wins hit testing
/// over both panes' content); the strip overflowed its viewport with its camera at the end, where a width change alone
/// cannot move that edge on screen: narrowing the left column only slid the camera back, a full-width column cannot widen,
/// and a release reveal of the focused right column put back any move a drag showed. A plain drag there trades its points
/// with the next column now (`DividerDragState.tradesAtStripEnd`), so the edge follows the pointer and stays where the
/// release leaves it.
@MainActor
@Suite(.closesItsWindows)
struct ColumnEdgeAtStripEndTests {
    /// Every pane's content is a plain view that takes clicks anywhere in its bounds, as a chat, terminal, browser or
    /// New Tab pane's content does.
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Rig {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        var ended: [LayoutIntent] = []

        /// A full-width left column and a right column split top (`p2`) and bottom (`p3`), the right one focused: the
        /// strip overflows and its camera rests at the end, the reported layout.
        init() {
            _ = NSApplication.shared
            let layout = ScreenLayout.columns([
                LayoutColumn(id: "c0", width: 1, root: .leaf("p1")),
                LayoutColumn(id: "c1", width: 0.5, root: .split("y", axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))),
            ])
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: "p2")
            model.followsDesignMetrics = false
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = true
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.borderless], backing: .buffered,
                              defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            for _ in 0..<240 where root.advanceFrame(1.0 / 120) {}
            root.layoutSubtreeIfNeeded()
            model.intentHandler = { [unowned self] intent in
                if case .setColumnWidth(_, _, _, _, .ended) = intent { ended.append(intent) }
                if case .setLayoutSizes = intent { ended.append(intent) }
            }
        }

        var screen: ScreenContentView { get throws { try #require(root.screenViews["s"]) } }
        var layout: ScreenLayout { model.screens[0].layout }
        func width(_ column: ColumnID) -> Double? { layout.columns.first { $0.id == column }?.width }

        func handle() throws -> DividerHandleView {
            try #require(try screen.dividerViews[.columnEdge("c0")], "no edge between the columns")
        }

        /// The x (window coordinates) where the left column ends on screen.
        func edgeX() throws -> CGFloat {
            let screen = try screen
            let frame = try #require(screen.displayedFrame(of: "p1"), "p1 shows no frame")
            return screen.convert(frame, to: nil).maxX
        }

        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        /// Drags the edge by `offsets` from the middle of its handle at height `y` (window coordinates); the edge's x
        /// after each move's frame, then the release and its landing.
        func drag(offsets: [CGFloat], y: CGFloat) throws -> [CGFloat] {
            let view = try handle()
            let from = CGPoint(x: view.convert(CGPoint(x: view.bounds.midX, y: 0), to: nil).x, y: y)
            view.mouseDown(with: event(.leftMouseDown, from))
            var shown: [CGFloat] = []
            for dx in offsets {
                view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: from.x + dx, y: from.y)))
                _ = root.advanceFrame(1.0 / 120)
                root.layoutSubtreeIfNeeded()
                shown.append(try edgeX())
            }
            view.mouseUp(with: event(.leftMouseUp, CGPoint(x: from.x + (offsets.last ?? 0), y: from.y)))
            root.syncWithModel()
            for _ in 0..<240 where root.advanceFrame(1.0 / 120) {}
            root.layoutSubtreeIfNeeded()
            return shown
        }
    }

    @Test func theLayoutOverflowsWithItsCameraAtTheEnd() throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        let screen = try rig.screen
        #expect(screen.geometry.maxOffset > 100, "the strip fits: \(screen.geometry.maxOffset)")
        #expect(DividerDrag.cameraHoldsStripEnd(maxOffset: screen.geometry.maxOffset, camera: screen.scroll.target),
                "the camera is not at the end: \(screen.scroll.target) of \(screen.geometry.maxOffset)")
    }

    /// The press goes to the divider wherever its band reaches over the panes beside it, on every edge of the layout:
    /// the column edge (beside the top and the bottom pane of the right column) and the split inside the right column.
    @Test func theDividerBandWinsHitTestingOverThePanesBesideIt() throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        let screen = try rig.screen
        let frame = try #require(rig.window.contentView?.superview ?? rig.window.contentView)
        var checked = 0
        for (kind, view) in screen.dividerViews where !view.isHidden {
            let band = view.convert(view.cursorRectInBounds, to: nil)
            guard band.width > 0, band.height > 0 else { continue }
            let points = view.axis == .horizontal
                ? [0.1, 0.5, 0.9].flatMap { f in [band.minX + 0.5, band.midX, band.maxX - 0.5].map { CGPoint(x: $0, y: band.minY + band.height * f) } }
                : [0.1, 0.5, 0.9].flatMap { f in [band.minY + 0.5, band.midY, band.maxY - 0.5].map { CGPoint(x: band.minX + band.width * f, y: $0) } }
            for point in points {
                let hit = frame.hitTest(frame.superview?.convert(point, from: nil) ?? point)
                #expect(hit === view, "\(kind.mouseAreaID) at \(point): the press goes to \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
                checked += 1
            }
        }
        #expect(checked >= 18, "too few divider bands to check: \(checked)")
    }

    /// Narrowing the full-width column: the edge follows the pointer, and the release leaves it there.
    @Test(arguments: [CGFloat(150), CGFloat(550)])
    func theEdgeFollowsANarrowingDragAndStays(_ y: CGFloat) throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        let start = try rig.edgeX()
        let offsets: [CGFloat] = [-40, -80, -120, -160]
        let shown = try rig.drag(offsets: offsets, y: y)
        for (x, dx) in zip(shown, offsets) {
            #expect(abs(x - (start + dx)) <= 1, "pointer \(dx) pt: the edge shows \(x - start) pt from the press")
        }
        let landed = try rig.edgeX()
        #expect(abs(landed - (start - 160)) <= 1, "the release put the edge \(landed - start) pt from the press, not -160")
        #expect((rig.width("c0") ?? 1) < 1, "the left column kept its width")
        #expect((rig.width("c1") ?? 0.5) > 0.5, "the right column did not take the points")
        #expect(rig.ended.count == 1)
    }

    /// Widening back after a narrowing drag: the edge follows again and stays (the release reveal of the focused right
    /// column no longer puts it back).
    @Test func theEdgeFollowsAWideningDragAndStays() throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        let start = try rig.edgeX()
        _ = try rig.drag(offsets: [-100, -200], y: 300)
        let narrowed = try rig.edgeX()
        try #require(abs(narrowed - (start - 200)) <= 1, "the narrowing drag did not move the edge: \(narrowed - start)")
        let offsets: [CGFloat] = [40, 80, 120]
        let shown = try rig.drag(offsets: offsets, y: 300)
        for (x, dx) in zip(shown, offsets) {
            #expect(abs(x - (narrowed + dx)) <= 1, "pointer +\(dx) pt: the edge shows \(x - narrowed) pt from the press")
        }
        let landed = try rig.edgeX()
        #expect(abs(landed - (narrowed + 120)) <= 1, "the release put the edge \(landed - narrowed) pt from the press, not +120")
    }

    /// A trade never takes the dragged column past the widest share: a full-width column dragged wider stays, and so
    /// does the column after it.
    @Test func aTradeKeepsTheDraggedColumnWithinTheWidestShare() {
        let strip = StripStart(columns: [.init(id: "a", width: 1, minimum: 100), .init(id: "b", width: 0.5, minimum: 100)],
                               viewport: 1000, gap: 0)
        let widths = Dictionary(uniqueKeysWithValues: strip.trading("a", to: 1.2).compactMap { value -> (ColumnID, Double)? in
            if case let .width(column, width) = value { (column, (width * 1000).rounded() / 1000) } else { nil }
        })
        #expect(widths == ["a": 1, "b": 0.5])
    }
}
