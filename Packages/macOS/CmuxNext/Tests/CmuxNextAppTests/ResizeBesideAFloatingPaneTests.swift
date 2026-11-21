import AppKit
import CmuxNextBridge
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A floating pane and a resize on the same screen: what goes out, and what each one leaves alone.
///
/// A key press that trades the width of 2 columns sends the 2 widths as one change; each width names a tiled pane
/// of its column, and the floating pane keeps its card and sends nothing. A key press on the floating pane itself
/// is refused (`PaneResize.press` returns false): it sends no intent and changes no size, on a screen of columns
/// and on a screen of splits. A pointer's resize of the floating pane after a trade sends its frame one time and
/// no size, and the 2 widths stay as the trade left them.
///
/// The limit of these rows: a layout model and its view in a window. The intents go to a list of the test, so no
/// app and no daemon answers them; what the app does with a refused press is not in these rows. Frames step at a
/// fixed 120 Hz dt, so each assert is about a frame, not about wall time.
@MainActor @Suite(.closesItsWindows) struct ResizeBesideAFloatingPaneTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    static let dt = 1.0 / 120
    static let columns: ScreenLayout = .columns([LayoutColumn(id: "c0", width: 0.5, root: .leaf("p0")),
                                                 LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1"))])
    static let splits: ScreenLayout = .splits(.split("h", axis: .horizontal, ratio: 0.5, a: .leaf("p0"), b: .leaf("p1")))
    static let floating = LayoutFloatingPane(pane: "f", frame: CGRect(x: 0.3, y: 0.2, width: 0.3, height: 0.4))

    /// One screen with the tiled panes `p0` and `p1` and the floating pane `f`, in a window with its motion on; the
    /// test is the clock.
    @MainActor final class Rig {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        /// Each intent that the model sent.
        var intents: [LayoutIntent] = []

        init(_ layout: ScreenLayout) {
            _ = NSApplication.shared
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout, floating: [ResizeBesideAFloatingPaneTests.floating])],
                                activeScreenID: "s", focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered,
                              defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            settle()
            model.intentHandler = { [unowned self] intent in intents.append(intent) }
        }

        var screen: ScreenContentView { get throws { try #require(root.screenViews["s"]) } }

        /// The intents that carry a size of the tiled layout: a split's ratio, a column's width, a row's height.
        var sizeIntents: [LayoutIntent] {
            intents.filter { intent in
                if case .setRowHeights = intent { return true }
                return intent.sizes != nil
            }
        }

        /// The intents that carry a floating pane's frame.
        var frameIntents: [LayoutIntent] { intents.filter { $0.floatingFrame != nil } }

        /// The width of each column, as the model shows it now.
        var widths: [Double] { model.screens[0].layout.columns.map(\.width) }

        /// The floating pane's frame, as the model shows it now.
        var floatingFrame: CGRect? { model.screens[0].floating.first?.frame }

        /// The floating pane's card in the screen's view.
        func card() throws -> CGRect {
            let screen = try screen
            return try #require(screen.geometry.floatingCards["f"])
        }

        @discardableResult
        func step() -> Bool { root.advanceFrame(ResizeBesideAFloatingPaneTests.dt) }

        func settle() {
            for _ in 0..<600 where step() {}
        }

        /// One key press on `pane`, with the frames of its spring.
        func press(_ pane: PaneID, _ direction: LayoutDirection) -> Bool {
            let moved = PaneResize.press(pane, direction, model: model, view: root)
            settle()
            root.layoutSubtreeIfNeeded()
            return moved
        }

        /// A pointer event at `point` (the window's coordinates).
        func pointer(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
    }

    /// A trade of 2 columns beside a floating pane: the 2 widths go out as one change, each with a tiled pane of its
    /// column; no frame of the floating pane goes out, and its card and its frame in the model stay.
    @Test func aTradeBesideAFloatingPaneSendsTheTwoWidthsAndLeavesThePane() throws {
        let rig = Rig(Self.columns)
        defer { rig.window.closeAfterTest() }
        let card = try rig.card(), frame = rig.floatingFrame, before = rig.widths

        #expect(rig.press("p1", .right), "the press on the tiled pane was refused")
        let sent = rig.sizeIntents
        guard sent.count == 1, case let .setLayoutSizes(values, _)? = sent.first else {
            Issue.record("the trade went out as \(sent)")
            return
        }
        var named: [ColumnID: PaneID] = [:]
        for value in values {
            guard case let .width(column, anyPane, _) = value else { continue }
            named[column] = anyPane
        }
        #expect(values.count == 2, "want the 2 columns' widths, got \(values)")
        #expect(named == ["c0": "p0", "c1": "p1"], "each width names a tiled pane of its column, got \(values)")
        #expect(rig.widths != before, "the trade changed no width: \(rig.widths)")

        #expect(rig.frameIntents.isEmpty, "the trade sent a frame of the floating pane: \(rig.frameIntents)")
        #expect(!rig.intents.contains(.raiseFloatingPane("f")), "the trade raised the floating pane: \(rig.intents)")
        #expect(rig.floatingFrame == frame, "the trade changed the floating pane's frame in the model")
        let after = try rig.card()
        #expect(after == card, "the trade moved the floating pane's card: \(card) to \(after)")
    }

    /// A key press on the floating pane that has the focus, each of the 4 directions: the press is refused, no
    /// intent goes out, and the tiled layout, the pane's frame and its card stay.
    @Test(arguments: ["columns", "splits"])
    func aPressOnAFloatingPaneIsRefusedAndSendsNothing(kind: String) throws {
        let rig = Rig(kind == "columns" ? Self.columns : Self.splits)
        defer { rig.window.closeAfterTest() }
        rig.model.focus("f", source: .keyboard)
        try #require(rig.model.focusedPane == "f", "the fixture: the floating pane has the focus")
        rig.settle()
        rig.intents = []
        let card = try rig.card(), frame = rig.floatingFrame, layout = rig.model.screens[0].layout

        for direction in LayoutDirection.allCases {
            #expect(!rig.press("f", direction), "\(kind): the press \(direction) on the floating pane was not refused")
        }
        #expect(rig.intents.isEmpty, "\(kind): a refused press sent \(rig.intents)")
        #expect(rig.model.screens[0].layout == layout, "\(kind): a refused press changed the tiled layout")
        #expect(rig.floatingFrame == frame, "\(kind): a refused press changed the floating pane's frame in the model")
        let after = try rig.card()
        #expect(after == card, "\(kind): a refused press moved the floating pane's card: \(card) to \(after)")
    }

    /// A pointer's resize of the floating pane by its right edge, after a trade of the 2 columns: the release sends
    /// the pane's frame one time and no size, and the 2 widths stay as the trade left them.
    @Test func aResizeOfTheFloatingPaneAfterATradeSendsItsFrameAndKeepsTheWidths() throws {
        let rig = Rig(Self.columns)
        defer { rig.window.closeAfterTest() }
        let before = rig.widths, frame = rig.floatingFrame
        try #require(rig.press("p1", .right), "the fixture: the trade went")
        try #require(rig.sizeIntents.count == 1, "the fixture: the trade went out one time, got \(rig.sizeIntents)")
        let traded = rig.widths
        try #require(traded != before, "the fixture: the trade changed the widths")
        rig.intents = []

        let screen = try rig.screen
        let card = try rig.card()
        let press = screen.convert(CGPoint(x: card.maxX - 1, y: card.midY), to: nil)
        try screen.handleFloatingDrag("f", .began(.right), event: rig.pointer(.leftMouseDown, at: press))
        for step in 1...10 {
            let point = CGPoint(x: press.x + CGFloat(step) * 8, y: press.y)
            try screen.handleFloatingDrag("f", .moved, event: rig.pointer(.leftMouseDragged, at: point))
            rig.step()
        }
        try screen.handleFloatingDrag("f", .ended, event: rig.pointer(.leftMouseUp, at: CGPoint(x: press.x + 80, y: press.y)))
        rig.settle()

        #expect(rig.frameIntents.count == 1, "the release sends the frame one time: \(rig.frameIntents)")
        #expect(rig.frameIntents.first?.floatingFrame == rig.floatingFrame, "the frame that went out is not the frame that the model shows")
        #expect(rig.floatingFrame != frame, "the resize changed no frame in the model")
        #expect(rig.sizeIntents.isEmpty, "the resize of the floating pane sent a size: \(rig.sizeIntents)")
        #expect(rig.widths == traded, "the resize of the floating pane changed the widths: \(traded) to \(rig.widths)")
        let wide = try rig.card()
        #expect(abs(wide.width - card.width - 80) < 1, "the card's right edge is where the pointer let go: \(card) to \(wide)")
    }
}
