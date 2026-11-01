import AppKit
@testable import CmuxNextLayout
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Closing the last column or row of a scrolling strip (Lawrence 2026-10-20: "the pane closes
/// immediately and immediately alongside the pane closing we also need to see a shift"). The close
/// and the camera shift it needs are one motion: the camera starts moving in the change that drops
/// the pane, follows the close spring every frame until it rests (never a second, different curve
/// after the panes land), and ends where the new layout puts it. Frames step at a fixed 120 Hz dt,
/// so every assertion is about frame N, not wall time.
@MainActor
@Suite(.closesItsWindows)
struct ColumnCloseScrollMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    static let dt = 1.0 / 120

    final class Strip {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init(_ layout: ScreenLayout, focused: PaneID, reduceMotion: Bool = false) {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: focused)
            model.rowsEnabledOverride = true
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = reduceMotion
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            settle()
        }

        var screen: ScreenContentView { root.screenViews["s"]! }

        /// The app's order for a close (`WorkspaceContentController.apply`): the daemon tree first
        /// (the model falls back to the screen's first pane), then the focus the topology lands.
        func close(to layout: ScreenLayout, focus: PaneID) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: layout)])
            root.syncWithModel()
            model.focus(focus, notify: false)
            root.syncWithModel()
        }

        @discardableResult
        func step() -> Bool { root.advanceFrame(ColumnCloseScrollMotionTests.dt) }

        func settle() { for _ in 0..<600 where step() {} }

        func shown(_ pane: PaneID) -> CGRect { screen.displayedFrame(of: pane) ?? .null }
    }

    static func columns(_ count: Int, width: Double = 0.5) -> ScreenLayout {
        .columns((1...count).map { LayoutColumn(id: ColumnID("c\($0)"), width: width, root: .leaf(PaneID("p\($0)"))) })
    }

    /// One full-width column of `heights.count` rows (permille each), as the daemon sends it: the
    /// rows, and the compat chain of vertical splits that holds every pane.
    static func rows(_ heights: [Int]) -> ScreenLayout {
        let rows = heights.enumerated().map { index, height in
            LayoutRow(id: RowID("r\(index + 1)"), height: height, root: .leaf(PaneID("p\(index + 1)")))
        }
        func chain(_ rest: ArraySlice<LayoutRow>) -> SplitNode {
            guard rest.count > 1, let first = rest.first else { return rest.first!.root }
            return .split(SplitID("v\(first.id.rawValue)"), axis: .vertical, ratio: 1 / Double(rest.count), a: first.root,
                          b: chain(rest.dropFirst()))
        }
        return .columns([LayoutColumn(id: "c1", width: 1, root: chain(rows[...]), rows: rows)])
    }

    /// The close spring the panes and the camera share (`PaneMotionVariant.standard`).
    static var closeSpring: SpringParameters { Motion.panes.policy.spring(PaneMotionVariant.standard.closeSpring) }

    /// Where a camera on the close spring is after `frames` frames, from `start` toward `end`
    /// (the change itself takes the first, `leadIfPending`).
    static func reference(from start: CGFloat, to end: CGFloat, frames: Int) -> CGFloat {
        var spring = SpringValue(start)
        spring.target = end
        for _ in 0..<frames { _ = spring.advance(dt, parameters: closeSpring, epsilon: 0.25) }
        return spring.value
    }

    // MARK: Columns

    /// Closing the focused last column, scrolled to the end: the frame that drops it already shows
    /// the strip shifting, every frame after is the close spring's, and it lands with the strip
    /// filling the window (no gap right of the last column). Measured on what shows (the camera
    /// and the carried pane frames together), so either one may carry the shift.
    @Test func closingTheLastColumnShiftsTheStripOnTheCloseSpringFromItsFirstFrame() throws {
        let strip = Strip(Self.columns(3), focused: "p3")
        defer { strip.window.closeAfterTest() }
        #expect(strip.screen.scroll.value > 100, "three half-width columns scroll to the end for p3 (offset \(strip.screen.scroll.value))")
        let start = strip.shown("p2").minX

        strip.close(to: Self.columns(2), focus: "p2")
        #expect(strip.root.context.hosts["p3"]?.superview == nil, "the closed pane leaves at once")
        #expect(abs(strip.screen.scroll.target) < 0.5, "two half-width columns fit: the camera rests at 0")
        // Frame 0: the pane is gone and the shift has begun in the same change.
        #expect(strip.shown("p2").minX > start + 0.5, "p2 slides right in the close's own frame")

        var shown = [strip.shown("p2").minX]
        var gaps = [strip.screen.bounds.maxX - strip.shown("p2").maxX]
        for _ in 0..<400 {
            let moving = strip.step()
            shown.append(strip.shown("p2").minX)
            gaps.append(strip.screen.bounds.maxX - strip.shown("p2").maxX)
            if !moving { break }
        }
        let end = shown.last!
        var worst: CGFloat = 0
        for (frame, x) in shown.enumerated() {
            worst = max(worst, abs(x - Self.reference(from: start, to: end, frames: frame + 1)))
        }
        #expect(worst < 2, "p2 follows the close spring every frame (worst drift \(worst) pt): \(shown)")
        #expect(zip(gaps, gaps.dropFirst()).allSatisfy { $1 <= $0 + 0.5 }, "the gap right of p2 only closes: \(gaps)")
        var reference = SpringValue(start)
        reference.target = end
        var referenceFrames = 0
        while reference.advance(Self.dt, parameters: Self.closeSpring, epsilon: 0.25) { referenceFrames += 1 }
        #expect(abs(shown.count - referenceFrames) <= 3, "the shift lasts as long as the close spring (\(shown.count) vs \(referenceFrames) frames)")
        // Rest: the strip fills the window, the first column at the leading padding.
        #expect(abs(strip.screen.scroll.value - strip.screen.scroll.target) < 0.01)
        let p1 = strip.shown("p1"), p2 = strip.shown("p2")
        #expect(p1.minX >= 0 && p1.minX < 40, "p1 rests at the leading edge (\(p1.minX))")
        #expect(abs((strip.screen.bounds.maxX - p2.maxX) - p1.minX) < 1.5, "the trailing gap equals the leading one")
    }

    /// A middle column closing while scrolled to the end: the column right of it slides over its
    /// space while the camera clamps, both on the close spring, and nothing jumps when the
    /// panes land (the camera keeps that spring until it rests too).
    @Test func closingAMiddleColumnAtTheEndMovesPanesAndCameraAsOneMotion() {
        let strip = Strip(Self.columns(4), focused: "p4")
        defer { strip.window.closeAfterTest() }
        let before = strip.shown("p4")
        strip.close(to: .columns([LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1")), LayoutColumn(id: "c2", width: 0.5, root: .leaf("p2")),
                                   LayoutColumn(id: "c4", width: 0.5, root: .leaf("p4"))]), focus: "p4")
        var positions = [before.minX, strip.shown("p4").minX]
        for _ in 0..<400 where strip.step() { positions.append(strip.shown("p4").minX) }
        positions.append(strip.shown("p4").minX)
        let steps = zip(positions, positions.dropFirst()).map { $1 - $0 }
        let travel = positions.last! - positions.first!
        // One critically damped motion: every step goes the same way, and none is a jump.
        #expect(steps.allSatisfy { travel >= 0 ? $0 >= -0.5 : $0 <= 0.5 }, "p4 never reverses: \(steps)")
        #expect(steps.allSatisfy { abs($0) <= max(abs(travel) * 0.2, 1) }, "no step jumps more than a fifth of the travel: \(steps)")
        let p4 = strip.shown("p4")
        #expect(abs((strip.screen.bounds.maxX - p4.maxX) - strip.shown("p1").minX) < 1.5 || p4.maxX <= strip.screen.bounds.maxX,
                "p4 rests inside the window")
        #expect(abs(strip.screen.scroll.value - strip.screen.scroll.target) < 0.01)
    }

    /// Reduce Motion: the close and the shift land in the change itself.
    @Test func reduceMotionClosesTheLastColumnInOneFrame() {
        let strip = Strip(Self.columns(3), focused: "p3", reduceMotion: true)
        defer { strip.window.closeAfterTest() }
        strip.close(to: Self.columns(2), focus: "p2")
        #expect(abs(strip.screen.scroll.value - strip.screen.scroll.target) < 0.01)
        #expect(abs(strip.screen.scroll.value) < 0.5)
        #expect(strip.step() == false)
    }

    // MARK: Rows

    /// Closing the focused last row of a column whose rows still overflow: the rows above shift
    /// down into view on the close spring from the close's own frame, and rest at the new end.
    @Test func closingTheLastRowShiftsTheRowsOnTheCloseSpringFromItsFirstFrame() throws {
        let strip = Strip(Self.rows([400, 400, 400, 400]), focused: "p4")
        defer { strip.window.closeAfterTest() }
        let rows = try #require(strip.screen.rowScrolls["c1"])
        #expect(rows.state.spring.value > 100, "four 400 permille rows scroll to the end for p4 (offset \(rows.state.spring.value))")
        let start = strip.shown("p3").minY

        strip.close(to: Self.rows([400, 400, 400]), focus: "p3")
        #expect(strip.shown("p3").minY > start + 0.5, "p3 slides down in the close's own frame")

        var shown = [strip.shown("p3").minY]
        for _ in 0..<400 {
            let moving = strip.step()
            shown.append(strip.shown("p3").minY)
            if !moving { break }
        }
        let end = shown.last!
        #expect(end > start + 50, "p3 moves down into view (\(start) -> \(end))")
        var worst: CGFloat = 0
        for (frame, y) in shown.enumerated() {
            worst = max(worst, abs(y - Self.reference(from: start, to: end, frames: frame + 1)))
        }
        #expect(worst < 2, "the rows follow the close spring every frame (worst drift \(worst) pt): \(shown)")
        #expect(strip.shown("p3").maxY <= strip.screen.bounds.maxY + 0.5, "p3 rests inside the column")
    }

    /// Closing the last row so the rest fit the column: the stack stops scrolling, and the rows
    /// still glide to their places instead of jumping by the offset they had.
    @Test func closingTheLastOverflowingRowGlidesWhenTheRestFit() {
        let strip = Strip(Self.rows([500, 500, 500]), focused: "p3")
        defer { strip.window.closeAfterTest() }
        #expect((strip.screen.rowScrolls["c1"]?.state.spring.value ?? 0) > 100)
        let before = strip.shown("p2")
        strip.close(to: Self.rows([500, 500]), focus: "p2")
        var positions = [before.minY, strip.shown("p2").minY]
        for _ in 0..<400 where strip.step() { positions.append(strip.shown("p2").minY) }
        positions.append(strip.shown("p2").minY)
        let steps = zip(positions, positions.dropFirst()).map { $1 - $0 }
        let travel = abs(positions.last! - positions.first!)
        #expect(travel > 50, "p2 has to move (\(positions.first!) -> \(positions.last!))")
        #expect(steps.allSatisfy { abs($0) <= max(travel * 0.2, 1) }, "no step jumps more than a fifth of the travel: \(steps)")
    }
}
