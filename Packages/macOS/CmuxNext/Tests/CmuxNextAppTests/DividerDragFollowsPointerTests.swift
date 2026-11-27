import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR KEYS (lead decision, STATUS 8923; the refactor owner's revised rule, 14:1xZ): a divider drag
/// has no hold-then-jump in any mode. Before: with no modifier a split divider held on a snap (1/3, 1/2, 2/3, the
/// chain's equal share) while the pointer was within 8 pt of it (`DividerDragState.snapDistance`), then jumped 8 pt to
/// the pointer (RESIZE KEYS films: 91-99 ms of a still divider at 120 Hz, then a lurch; #32988), and a release with
/// speed landed on a snap the pointer never reached. With Shift the divider jumped from snap to snap while the pointer
/// moved.
///
/// Now: the divider is under the pointer in every frame, with no modifier and with Shift. No modifier lands where the
/// pointer lets go. Shift lands on the nearest snap at the release (split: 1/3, 1/2, 2/3, the chain's equal share;
/// column edge: the preset widths), and the release's spring carries the divider there. Letting go of Shift first lands
/// where the pointer is.
///
/// From #32988 (RESIZE KEYS, superseded): its `aDragThatStartsOnASnapFollowsThePointerFromItsFirstPoint` is kept here
/// (with Shift too); its tests that a no-modifier drag snaps back onto a half, or snaps onto one from 4 pt away, are
/// the soft snap this change removes.
///
/// A move keeps the pointer and the next display frame applies it (`DividerDrag.applyWaiting`, FRAME OWNER REFACTOR S2),
/// so the divider is read after that frame.
@MainActor
@Suite(.closesItsWindows)
struct DividerDragFollowsPointerTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Rig {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        var ended: [LayoutIntent] = []

        init(_ layout: ScreenLayout, animates: Bool = false) {
            _ = NSApplication.shared
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = !animates
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.borderless], backing: .buffered,
                              defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            model.intentHandler = { [unowned self] intent in
                switch intent {
                case .setSplitRatio(_, _, _, .ended), .setColumnWidth(_, _, _, _, .ended): ended.append(intent)
                default: break
                }
            }
        }

        var screen: ScreenContentView { get throws { try #require(root.screenViews["s"]) } }
        var layout: ScreenLayout { model.screens[0].layout }

        func handle(_ kind: DividerHandleView.Kind) throws -> DividerHandleView {
            try #require(try screen.dividerViews[kind], "no handle \(kind)")
        }

        /// Where the press starts: the middle of `kind`'s handle, in window coordinates.
        func start(_ kind: DividerHandleView.Kind) throws -> CGPoint {
            let view = try handle(kind)
            return view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        }

        func event(_ type: NSEvent.EventType, _ point: CGPoint, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        /// The divider's shown x (window coordinates) after each move of a drag of `kind` by `offsets` (points from the
        /// press), then the release at the last offset with `releaseFlags` (the drag's flags when nil).
        @discardableResult
        func drag(_ kind: DividerHandleView.Kind, offsets: [CGFloat], flags: NSEvent.ModifierFlags = [],
                  releaseFlags: NSEvent.ModifierFlags? = nil, edge: () throws -> CGFloat) throws -> [CGFloat] {
            let view = try handle(kind)
            let from = try start(kind)
            view.mouseDown(with: event(.leftMouseDown, from, flags))
            var shown: [CGFloat] = []
            for dx in offsets {
                view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: from.x + dx, y: from.y), flags))
                // The move shows in the next display frame: until then it only waits.
                #expect(try screen.activeDrag?.waiting == true, "the move did not wait for the frame tick")
                _ = root.advanceFrame(1.0 / 120)
                shown.append(try edge())
            }
            view.mouseUp(with: event(.leftMouseUp, CGPoint(x: from.x + (offsets.last ?? 0), y: from.y), releaseFlags ?? flags))
            root.syncWithModel()
            return shown
        }

        /// The x (window coordinates) of the left pane's right edge: the split divider as the screen shows it.
        func dividerX(_ left: PaneID) throws -> CGFloat {
            let screen = try screen
            let frame = try #require(screen.displayedFrame(of: left), "\(left) shows no frame")
            return screen.convert(frame, to: nil).maxX
        }

        func ratio(_ split: SplitID) -> Double? { layout.ratio(of: split) }

        /// Half a device pixel at the screen's backing scale (and float slack): the farthest a divider that follows the
        /// pointer can show from it once its edge is rounded to the pixel grid.
        var halfPixel: CGFloat { get throws { 0.5 / max(try screen.scale, 1) + 0.01 } }
        func width(_ column: ColumnID) -> Double? { layout.columns.first { $0.id == column }?.width }

        /// A split's room for its two sides, in points.
        func room(_ split: SplitID) throws -> CGFloat {
            let divider = try #require(try screen.geometry.dividers.first { $0.id == split })
            return divider.container.width - root.context.style.dividerThickness
        }

        /// Steps display frames until nothing moves (at most 2 s of them); the x of `left`'s right edge after each.
        func land(_ left: PaneID) throws -> [CGFloat] {
            var shown: [CGFloat] = [], frames = 0
            while frames < 240, root.advanceFrame(1.0 / 120) {
                root.layoutSubtreeIfNeeded()
                shown.append(try dividerX(left))
                frames += 1
            }
            return shown
        }
    }

    static var even: ScreenLayout { .splits(.split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))) }

    /// Each shown divider position is the press position plus the pointer's move, within half a device pixel (`tolerance`):
    /// a divider held still even for one pixel of pointer travel fails.
    static func expectFollows(_ shown: [CGFloat], from start: CGFloat, offsets: [CGFloat], tolerance: CGFloat, _ what: String,
                              sourceLocation: SourceLocation = #_sourceLocation) {
        for (index, (x, dx)) in zip(shown, offsets).enumerated() {
            #expect(abs(x - (start + dx)) <= tolerance, "\(what): move \(index) (pointer +\(dx) pt) shows the divider \(x - start) pt from the press",
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: No modifier

    /// #32988's case: a drag that starts on a snap (an even split) follows the pointer from its first point, with no
    /// modifier and with Shift.
    @Test(arguments: [CGFloat(1), 3, 6, -3], [false, true])
    func aDragThatStartsOnASnapFollowsThePointerFromItsFirstPoint(_ dx: CGFloat, _ shift: Bool) throws {
        let rig = Rig(Self.even)
        defer { rig.window.closeAfterTest() }
        let start = try rig.dividerX("p1")
        let shown = try rig.drag(.split("x"), offsets: [dx / 2, dx], flags: shift ? .shift : [], releaseFlags: []) { try rig.dividerX("p1") }
        Self.expectFollows(shown, from: start, offsets: [dx / 2, dx], tolerance: try rig.halfPixel, shift ? "Shift" : "no modifier")
    }

    /// A slow drag across a half and a third: the divider never holds on a snap, never jumps to one.
    @Test(arguments: [false, true])
    func aSlowDragAcrossSnapsFollowsThePointerInEveryFrame(_ shift: Bool) throws {
        let rig = Rig(.splits(.split("x", axis: .horizontal, ratio: 0.3, a: .leaf("p1"), b: .leaf("p2"))))
        defer { rig.window.closeAfterTest() }
        let start = try rig.dividerX("p1")
        let room = try rig.room("x")
        // From 0.3 to past 2/3, one point a move: through 1/3, the half and 2/3.
        let offsets = (1...Int(room * 0.4)).map { CGFloat($0) }
        let shown = try rig.drag(.split("x"), offsets: offsets, flags: shift ? .shift : []) { try rig.dividerX("p1") }
        Self.expectFollows(shown, from: start, offsets: offsets, tolerance: try rig.halfPixel, shift ? "Shift" : "no modifier")
    }

    /// No modifier: the release lands where the pointer let go, 4 pt from the half (the old soft snap took it there).
    @Test func withoutAModifierTheReleaseLandsUnderThePointer() throws {
        let rig = Rig(.splits(.split("x", axis: .horizontal, ratio: 0.45, a: .leaf("p1"), b: .leaf("p2"))))
        defer { rig.window.closeAfterTest() }
        let room = try rig.room("x")
        try rig.drag(.split("x"), offsets: [room * 0.05 - 4]) { try rig.dividerX("p1") }
        let ratio = try #require(rig.ratio("x"))
        #expect(abs(CGFloat(ratio - 0.5) * room + 4) <= 1, "the release put the divider \((ratio - 0.5) * Double(room)) pt from the half, want -4")
    }

    /// No modifier: a fast release near a snap lands where the pointer let go (the old fling snap took it to the half).
    @Test func withoutAModifierAFastReleaseLandsUnderThePointer() throws {
        let rig = Rig(.splits(.split("x", axis: .horizontal, ratio: 0.4, a: .leaf("p1"), b: .leaf("p2"))), animates: true)
        defer { rig.window.closeAfterTest() }
        let room = try rig.room("x")
        let view = try rig.handle(.split("x"))
        let from = try rig.start(.split("x"))
        // Let go 25 pt short of the half at 500 pt/s: the release projection (`motion.divider.releaseProjection`, 0.05 s)
        // puts that onto the half, where the old fling snap landed it. The speed is set, not timed: no test sleeps.
        let target = room * 0.1 - 25
        view.mouseDown(with: rig.event(.leftMouseDown, from, []))
        view.mouseDragged(with: rig.event(.leftMouseDragged, CGPoint(x: from.x + target / 2, y: from.y), []))
        view.mouseDragged(with: rig.event(.leftMouseDragged, CGPoint(x: from.x + target, y: from.y), []))
        let screen = try rig.screen
        screen.activeDrag?.velocity = 500
        screen.activeDrag?.pointer?.time = CACurrentMediaTime()
        view.mouseUp(with: rig.event(.leftMouseUp, CGPoint(x: from.x + target, y: from.y), []))
        rig.root.syncWithModel()
        let ratio = try #require(rig.ratio("x"))
        #expect(abs(CGFloat(ratio - 0.5) * room + 25) <= 1, "the fling landed \((ratio - 0.5) * Double(room)) pt from the half, want -25")
    }

    // MARK: Shift

    /// Shift: the divider follows the pointer during the drag; the release lands on the nearest snap.
    @Test func shiftLandsTheReleaseOnTheNearestSnap() throws {
        let rig = Rig(.splits(.split("x", axis: .horizontal, ratio: 0.3, a: .leaf("p1"), b: .leaf("p2"))))
        defer { rig.window.closeAfterTest() }
        let room = try rig.room("x")
        let start = try rig.dividerX("p1")
        // To 0.44: far from every snap, nearest the half.
        let offsets = [room * 0.07, room * 0.14]
        let shown = try rig.drag(.split("x"), offsets: offsets, flags: .shift) { try rig.dividerX("p1") }
        Self.expectFollows(shown, from: start, offsets: offsets, tolerance: try rig.halfPixel, "Shift")
        #expect(rig.ratio("x") == 0.5)
        #expect(rig.ended.count == 1)
    }

    /// Shift on a column edge: the column follows the pointer; the release lands on the nearest preset width.
    @Test func shiftLandsAColumnEdgeReleaseOnAPresetWidth() throws {
        let columns: ScreenLayout = .columns([LayoutColumn(id: "c0", width: 0.4, root: .leaf("p1")), LayoutColumn(id: "c1", width: 0.4, root: .leaf("p2"))])
        let rig = Rig(columns)
        defer { rig.window.closeAfterTest() }
        let start = try rig.dividerX("p1")
        let shown = try rig.drag(.columnEdge("c0"), offsets: [30, 60], flags: .shift) { try rig.dividerX("p1") }
        Self.expectFollows(shown, from: start, offsets: [30, 60], tolerance: try rig.halfPixel, "Shift column edge")
        #expect(rig.width("c0") == 0.5)
    }

    /// Option takes a Shift drag over (a split in a scrolling column pushes the columns after it, resize-modifiers.md):
    /// the push lands where the pointer is, so the drag forgets the snap Shift would land on. Shift alone again finds it
    /// as new (its alignment haptic plays again).
    @Test func aPushForgetsTheSnapAShiftReleaseWouldLandOn() throws {
        let columns: ScreenLayout = .columns([LayoutColumn(id: "c0", width: 0.6, root: .split("x", axis: .horizontal, ratio: 0.3, a: .leaf("p1"), b: .leaf("p2"))),
                                              LayoutColumn(id: "c1", width: 0.4, root: .leaf("p3"))])
        let rig = Rig(columns)
        defer { rig.window.closeAfterTest() }
        let room = try rig.room("x")
        let view = try rig.handle(.split("x"))
        let from = try rig.start(.split("x"))
        // To 0.44 with Shift: the release would land on the half.
        view.mouseDown(with: rig.event(.leftMouseDown, from, .shift))
        view.mouseDragged(with: rig.event(.leftMouseDragged, CGPoint(x: from.x + room * 0.14, y: from.y), .shift))
        _ = rig.root.advanceFrame(1.0 / 120) // the frame tick writes the move
        let screen = try rig.screen
        try #require(screen.activeDrag?.push != nil, "the split does not push: no scrolling column")
        #expect(screen.activeDrag?.snapped == 0.5)
        func flags(_ flags: NSEvent.ModifierFlags) {
            view.flagsChanged(with: NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
                                                     windowNumber: rig.window.windowNumber, context: nil, characters: "",
                                                     charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!)
            _ = rig.root.advanceFrame(1.0 / 120) // the frame tick writes the new mode
        }
        flags([.option, .shift])
        #expect(screen.activeDrag?.snapped == nil, "the push kept the snap of the Shift landing")
        flags(.option)
        flags(.shift)
        #expect(screen.activeDrag?.snapped == 0.5)
        view.mouseUp(with: rig.event(.leftMouseUp, CGPoint(x: from.x + room * 0.14, y: from.y), .shift))
        #expect(rig.ratio("x") == 0.5)
    }

    /// Letting go of Shift before the release lands where the pointer is.
    @Test func lettingGoOfShiftBeforeTheReleaseLandsUnderThePointer() throws {
        let rig = Rig(.splits(.split("x", axis: .horizontal, ratio: 0.3, a: .leaf("p1"), b: .leaf("p2"))))
        defer { rig.window.closeAfterTest() }
        let room = try rig.room("x")
        try rig.drag(.split("x"), offsets: [room * 0.07, room * 0.14], flags: .shift, releaseFlags: []) { try rig.dividerX("p1") }
        let ratio = try #require(rig.ratio("x"))
        #expect(abs(ratio - 0.44) < 0.002, "the release landed at \(ratio), want the pointer's 0.44")
    }

    /// Shift's landing moves on the release spring: no frame jumps, and the frames run from the pointer to the snap.
    @Test func shiftsLandingMovesOnTheReleaseSpring() throws {
        let rig = Rig(.splits(.split("x", axis: .horizontal, ratio: 0.3, a: .leaf("p1"), b: .leaf("p2"))), animates: true)
        defer { rig.window.closeAfterTest() }
        let room = try rig.room("x")
        let start = try rig.dividerX("p1")
        let released = start + room * 0.14
        try rig.drag(.split("x"), offsets: [room * 0.07, room * 0.14], flags: .shift) { try rig.dividerX("p1") }
        #expect(rig.ratio("x") == 0.5)
        let snap = start + room * 0.2
        let frames = try rig.land("p1")
        #expect(frames.count > 2, "the landing did not spring (\(frames.count) frames)")
        var last = released
        for (index, x) in frames.enumerated() {
            #expect(x >= last - 0.5 && x <= snap + 0.5, "frame \(index): the divider at \(x) left the path \(released) -> \(snap)")
            // The spring's largest frame step is about 13% of the travel (0.06 of the room): a quarter of it is a jump.
            #expect(x - last < room * 0.06 * 0.25, "frame \(index): a jump of \(x - last) pt")
            last = x
        }
        #expect(abs(last - snap) <= 1, "the landing rests at \(last), want the half at \(snap)")
    }
}
