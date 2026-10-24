import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CoreGraphics
import Testing

/// `layout.scrollModifier` (Lawrence 2026-10-24: "scrolling when there's columns and rows needs to
/// be better and easier. (maybe cmd scroll should be for scroll, else should go to the pane that is
/// below cursor)"). With `command`, the default, a plain scroll on either axis goes to the pane
/// under the pointer, whatever its content, and Command + scroll moves the layout from anywhere:
/// sideways pans the columns strip, up and down scrolls the column's rows. The first event of a
/// gesture decides its owner through its momentum; a wheel decides per notch. `none` is the rule
/// before it: sideways over a pane pans the strip, rows scroll over their gaps or with Command.
@MainActor
struct LayoutScrollModifierTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Window {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)

        /// Three 60% columns on a 1000 pt window, so the strip overflows; the first column holds three
        /// 750-unit rows (`top`, `middle`, `bottom`), so its rows overflow too.
        init(modifier: LayoutScrollModifier?, focusFollowsMouse: Bool = false) {
            let rows = [LayoutRow(id: "r1", height: 750, root: .leaf("top")),
                        LayoutRow(id: "r2", height: 750, root: .leaf("middle")),
                        LayoutRow(id: "r3", height: 750, root: .leaf("bottom"))]
            let tree: SplitNode = .split("lower", axis: .vertical, ratio: 0.5,
                                         a: .split("upper", axis: .vertical, ratio: 0.5, a: .leaf("top"), b: .leaf("middle")),
                                         b: .leaf("bottom"))
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([
                LayoutColumn(id: "c1", width: 0.6, root: tree, rows: rows),
                LayoutColumn(id: "c2", width: 0.6, root: .leaf("p2")),
                LayoutColumn(id: "c3", width: 0.6, root: .leaf("p3")),
            ]))], activeScreenID: "s", focusedPane: "top")
            model.followsDesignMetrics = false
            model.rowsEnabledOverride = true
            model.scrollModifierOverride = modifier
            model.focusFollowsMouseOverride = focusFollowsMouse
            var signals = ScrollFocusSignals()
            signals.secondsSinceKeyDown = { 60 }
            signals.windowIsKey = { _ in true }
            signals.mouseButtonsDown = { false }
            root = LayoutRootView(model: model, contentProvider: provider, scrollFocusSignals: signals)
            root.context.reduceMotionOverride = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            // The test is the clock: the display link never ticks.
            root.driver.isManual = true
        }

        /// The center of `pane` in window coordinates.
        func center(_ pane: PaneID) throws -> CGPoint {
            let frame = try #require(root.frame(of: pane))
            return root.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        }

        /// A point in the gap between `top` and `middle` (window coordinates).
        func rowGap() throws -> CGPoint {
            let top = try #require(root.frame(of: "top")), middle = try #require(root.frame(of: "middle"))
            #expect(middle.minY > top.maxY, "the rows have a gap: \(top) \(middle)")
            return root.convert(CGPoint(x: top.midX, y: (top.maxY + middle.minY) / 2), to: nil)
        }

        /// One scroll event at `point`, as the layout's monitor sees it. True: the layout took it.
        @discardableResult
        func scroll(at point: CGPoint, dx: Int32 = 0, dy: Int32 = 0, phase: CGScrollPhase? = nil,
                    momentum: CGMomentumScrollPhase = .none, units: CGScrollEventUnit = .pixel, command: Bool = false) -> Bool {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
            if units == .pixel { cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
            if let phase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
            if command { cg.flags = .maskCommand }
            return root.handleScroll(NSEvent(cgEvent: cg)!, locationInWindow: point)
        }

        /// A trackpad gesture: began, three changes, ended, then a coast of momentum. `commandAt`
        /// says which events have Command held (by index: 0 began, 1-3 changes, 4 ended, 5-7
        /// momentum). Returns how many of the 8 events the layout took.
        @discardableResult
        func gesture(at point: CGPoint, dx: Int32 = 0, dy: Int32 = 0, commandAt: Set<Int> = []) -> Int {
            var taken = 0
            if scroll(at: point, dx: dx, dy: dy, phase: .began, command: commandAt.contains(0)) { taken += 1 }
            for index in 1...3 where scroll(at: point, dx: dx, dy: dy, phase: .changed, command: commandAt.contains(index)) { taken += 1 }
            if scroll(at: point, phase: .ended, command: commandAt.contains(4)) { taken += 1 }
            let coast: [CGMomentumScrollPhase] = [.begin, .continuous, .end]
            for (offset, phase) in coast.enumerated()
                where scroll(at: point, dx: phase == .end ? 0 : dx / 2, dy: phase == .end ? 0 : dy / 2, momentum: phase,
                             command: commandAt.contains(5 + offset)) { taken += 1 }
            return taken
        }

        func settle() { for _ in 0..<600 { if !root.advanceFrame(1.0 / 120) { break } } }
    }

    // MARK: command (default)

    @Test func theDefaultIsCommand() {
        #expect(LayoutModel().scrollModifier == .command)
        let model = LayoutModel()
        model.followsDesignMetrics = false
        #expect(model.scrollModifier == .command)
    }

    @Test func aPlainSidewaysSwipeOverATerminalPaneNeverMovesTheStrip() throws {
        let w = Window(modifier: .command)
        let before = try #require(w.root.frame(of: "p2"))
        #expect(w.gesture(at: try w.center("p2"), dx: -20) == 0, "the pane under the pointer gets every event")
        w.settle()
        #expect(w.root.frame(of: "p2") == before, "the strip did not move")
    }

    @Test func aCommandSidewaysSwipeOverTheSamePaneMovesTheStrip() throws {
        let w = Window(modifier: .command)
        let before = try #require(w.root.frame(of: "p2"))
        #expect(w.gesture(at: try w.center("p2"), dx: -20, commandAt: Set(0...7)) == 8, "the layout takes the gesture and its coast")
        w.settle()
        let after = try #require(w.root.frame(of: "p2"))
        #expect(after.minX < before.minX - 100, "the strip panned left: \(before) -> \(after)")
    }

    @Test func aPlainVerticalScrollOverAPaneInAnOverflowingColumnScrollsThePane() throws {
        let w = Window(modifier: .command)
        let before = try #require(w.root.frame(of: "top"))
        #expect(w.gesture(at: try w.center("top"), dy: -20) == 0)
        #expect(w.scroll(at: try w.center("top"), dy: -1, units: .line) == false, "a wheel notch too")
        w.settle()
        #expect(w.root.frame(of: "top") == before, "the rows did not move")
    }

    @Test func aCommandVerticalScrollOverAPaneScrollsTheRows() throws {
        let w = Window(modifier: .command)
        let before = try #require(w.root.frame(of: "top"))
        #expect(w.gesture(at: try w.center("top"), dy: -30, commandAt: Set(0...7)) == 8)
        w.settle()
        let after = try #require(w.root.frame(of: "top"))
        #expect(after.minY < before.minY - 100, "the rows scrolled up: \(before) -> \(after)")
        #expect(after.minX == before.minX, "the strip stayed")
    }

    @Test func aPlainVerticalScrollOverTheGapBetweenRowsScrollsTheRows() throws {
        let w = Window(modifier: .command)
        let before = try #require(w.root.frame(of: "top"))
        #expect(w.gesture(at: try w.rowGap(), dy: -30) == 8, "chrome with no pane under it is the layout's")
        w.settle()
        #expect(try #require(w.root.frame(of: "top")).minY < before.minY - 100)
    }

    @Test func pressingCommandMidGestureDoesNotTakeAPaneGesture() throws {
        let w = Window(modifier: .command)
        let before = try #require(w.root.frame(of: "p2"))
        #expect(w.gesture(at: try w.center("p2"), dx: -20, commandAt: Set(1...7)) == 0, "the first event gave it to the pane")
        w.settle()
        #expect(w.root.frame(of: "p2") == before)
    }

    @Test func releasingCommandMidGestureKeepsTheLayoutsGestureAndMomentum() throws {
        let w = Window(modifier: .command)
        let before = try #require(w.root.frame(of: "p2"))
        #expect(w.gesture(at: try w.center("p2"), dx: -20, commandAt: [0]) == 8, "the first event gave it to the layout")
        w.settle()
        #expect(try #require(w.root.frame(of: "p2")).minX < before.minX - 100)
    }

    /// A trackpad touch sends `mayBegin` before `began`: the touch decides, so Command pressed or
    /// released between them changes nothing (PL-motion-core review 2026-10-24).
    @Test func commandAtTheTouchDecidesEvenWhenReleasedBeforeTheGestureBegins() throws {
        let w = Window(modifier: .command)
        let p2 = try w.center("p2")
        let before = try #require(w.root.frame(of: "p2"))
        w.scroll(at: p2, phase: .mayBegin, command: true)
        #expect(w.scroll(at: p2, dx: -20, phase: .began), "Command at the touch gave the gesture to the layout")
        for _ in 0..<3 { #expect(w.scroll(at: p2, dx: -20, phase: .changed)) }
        #expect(w.scroll(at: p2, phase: .ended))
        w.settle()
        #expect(try #require(w.root.frame(of: "p2")).minX < before.minX - 30, "the strip panned")
    }

    @Test func commandPressedAfterTheTouchDoesNotTakeThePanesGesture() throws {
        let w = Window(modifier: .command)
        let p2 = try w.center("p2")
        let before = try #require(w.root.frame(of: "p2"))
        w.scroll(at: p2, phase: .mayBegin)
        #expect(w.scroll(at: p2, dx: -20, phase: .began, command: true) == false, "the touch gave the gesture to the pane")
        for _ in 0..<3 { #expect(w.scroll(at: p2, dx: -20, phase: .changed, command: true) == false) }
        #expect(w.scroll(at: p2, phase: .ended, command: true) == false)
        w.settle()
        #expect(w.root.frame(of: "p2") == before)
    }

    /// Command + scroll always means the layout: a vertical trackpad gesture over a column whose
    /// rows do not overflow pans the strip, as a Command vertical wheel notch does.
    @Test func aCommandVerticalSwipeOverAColumnWithoutRowsPansTheStrip() throws {
        let w = Window(modifier: .command)
        let before = try #require(w.root.frame(of: "p2"))
        #expect(w.gesture(at: try w.center("p2"), dy: -20, commandAt: Set(0...7)) == 8, "the layout takes the gesture and its coast")
        w.settle()
        let after = try #require(w.root.frame(of: "p2"))
        #expect(after.minX < before.minX - 100, "the strip panned: \(before) -> \(after)")
        #expect(after.minY == before.minY)
    }

    @Test func aWheelNotchDecidesPerNotch() throws {
        let w = Window(modifier: .command)
        let p2 = try w.center("p2")
        // A mouse's Shift+wheel arrives as a discrete horizontal notch.
        #expect(w.scroll(at: p2, dx: -1, units: .line) == false, "a plain notch is the pane's")
        #expect(w.scroll(at: p2, dx: -1, units: .line, command: true), "the next one, with Command, is the strip's")
        #expect(w.scroll(at: p2, dx: -1, units: .line) == false, "and the next plain one is the pane's again")
    }

    @Test func aCommandVerticalWheelOverAColumnWithoutRowsPansTheStrip() throws {
        let w = Window(modifier: .command)
        let before = try #require(w.root.frame(of: "p2"))
        #expect(w.scroll(at: try w.center("p2"), dy: -1, units: .line, command: true), "a one-wheel mouse still pans the columns")
        w.settle()
        #expect(try #require(w.root.frame(of: "p2")).minX < before.minX - 100)
    }

    @Test func aPlainScrollDoesNotMoveFocusWithFocusFollowsMouseOff() throws {
        let w = Window(modifier: .command, focusFollowsMouse: false)
        w.gesture(at: try w.center("p2"), dx: -20)
        w.gesture(at: try w.center("p2"), dy: -20)
        w.scroll(at: try w.center("p2"), dy: -1, units: .line)
        #expect(w.model.focusedPane == "top")
    }

    @Test func aPlainScrollFocusesThePaneWithFocusFollowsMouseOn() throws {
        let w = Window(modifier: .command, focusFollowsMouse: true)
        w.gesture(at: try w.center("p2"), dx: -20)
        #expect(w.model.focusedPane == "p2")
    }

    @Test func overACanvasAPlainScrollIsThePanesAndCommandPansTheCanvas() throws {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(
            .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b"))))], activeScreenID: "s", focusedPane: "a")
        model.followsDesignMetrics = false
        model.scrollModifierOverride = .command
        let provider = Panes()
        let root = LayoutRootView(model: model, contentProvider: provider)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        let seed: [PaneID: CGRect] = ["a": CGRect(x: 0, y: 0, width: 600, height: 700), "b": CGRect(x: 600, y: 0, width: 600, height: 700)]
        #expect(model.toggleCanvas(seed: seed, viewport: CGSize(width: 1200, height: 700)))
        root.syncWithModel()
        let frame = try #require(root.frame(of: "a"))
        let point = root.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        func scroll(_ phase: CGScrollPhase, dx: Int32, command: Bool) -> Bool {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0)!
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            if command { cg.flags = .maskCommand }
            return root.handleScroll(NSEvent(cgEvent: cg)!, locationInWindow: point)
        }
        #expect(scroll(.began, dx: -20, command: false) == false, "a plain sideways gesture over a canvas pane is the pane's")
        #expect(scroll(.changed, dx: -20, command: false) == false)
        #expect(scroll(.ended, dx: 0, command: false) == false)
        #expect(root.frame(of: "a") == frame)
        #expect(scroll(.began, dx: -20, command: true), "Command pans the canvas")
        #expect(scroll(.changed, dx: -20, command: true))
        #expect(scroll(.ended, dx: 0, command: true))
        #expect(try #require(root.frame(of: "a")).minX < frame.minX, "the canvas panned")
    }

    // MARK: none (the rule before)

    @Test func noneLetsAPlainSidewaysSwipeOverAPaneMoveTheStrip() throws {
        let w = Window(modifier: .noModifier)
        let before = try #require(w.root.frame(of: "p2"))
        #expect(w.gesture(at: try w.center("p2"), dx: -20) == 8)
        w.settle()
        #expect(try #require(w.root.frame(of: "p2")).minX < before.minX - 100)
    }

    @Test func noneKeepsAPlainVerticalScrollOverAPaneWithThePaneAndCommandScrollsRows() throws {
        let w = Window(modifier: .noModifier)
        let before = try #require(w.root.frame(of: "top"))
        #expect(w.gesture(at: try w.center("top"), dy: -30) == 0)
        #expect(w.gesture(at: try w.center("top"), dy: -30, commandAt: Set(0...7)) == 8)
        w.settle()
        #expect(try #require(w.root.frame(of: "top")).minY < before.minY - 100)
    }

    @Test func noneKeepsAPlainVerticalWheelOverAColumnWithoutRowsWithThePane() throws {
        let w = Window(modifier: .noModifier)
        #expect(w.scroll(at: try w.center("p2"), dy: -1, units: .line, command: true) == false)
    }
}
