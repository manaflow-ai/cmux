import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
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
@Suite(.closesItsWindows)
struct LayoutScrollModifierTests {
    final class Panes: LayoutPaneContentProvider {
        /// Each pane's content view, as the layout asked for it.
        var views: [PaneID: NSView] = [:]
        /// Builds a pane's content view; a plain view unless a test needs a real one.
        var make: (PaneID) -> NSView = { _ in NSView() }
        func makeContentView(for pane: PaneID) -> NSView {
            let view = make(pane)
            views[pane] = view
            return view
        }
    }

    /// Three 60% columns, so the strip overflows on a root 1000 pt or less wide; the first column
    /// holds three 750-unit rows (`top`, `middle`, `bottom`), so its rows overflow too.
    static func columnsModel(modifier: LayoutScrollModifier?, focusFollowsMouse: Bool = false) -> LayoutModel {
        let rows = [LayoutRow(id: "r1", height: 750, root: .leaf("top")),
                    LayoutRow(id: "r2", height: 750, root: .leaf("middle")),
                    LayoutRow(id: "r3", height: 750, root: .leaf("bottom"))]
        let tree: SplitNode = .split("lower", axis: .vertical, ratio: 0.5,
                                     a: .split("upper", axis: .vertical, ratio: 0.5, a: .leaf("top"), b: .leaf("middle")),
                                     b: .leaf("bottom"))
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([
            LayoutColumn(id: "c1", width: 0.6, root: tree, rows: rows),
            LayoutColumn(id: "c2", width: 0.6, root: .leaf("p2")),
            LayoutColumn(id: "c3", width: 0.6, root: .leaf("p3")),
        ]))], activeScreenID: "s", focusedPane: "top")
        model.followsDesignMetrics = false
        model.rowsEnabledOverride = true
        model.scrollModifierOverride = modifier
        model.focusFollowsMouseOverride = focusFollowsMouse
        return model
    }

    /// One scroll event at `point`, as a layout's monitor sees it. True: `root` took it.
    @discardableResult
    static func scroll(_ root: LayoutRootView, at point: CGPoint, dx: Int32 = 0, dy: Int32 = 0, phase: CGScrollPhase? = nil,
                       momentum: CGMomentumScrollPhase = .none, units: CGScrollEventUnit = .pixel, command: Bool = false) -> Bool {
        root.handleScroll(event(dx: dx, dy: dy, phase: phase, momentum: momentum, units: units, command: command),
                          locationInWindow: point)
    }

    /// A synthesized scroll event (no window: the test says where it came from).
    static func event(dx: Int32 = 0, dy: Int32 = 0, phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase = .none,
                      units: CGScrollEventUnit = .pixel, command: Bool = false) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
        if units == .pixel { cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
        if let phase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        if command { cg.flags = .maskCommand }
        return NSEvent(cgEvent: cg)!
    }

    /// `child` added to `parent` over `rectInParent` (window coordinates), as a Chromium page
    /// window or a divider catcher panel sits over the layout's window.
    static func attach(_ child: NSWindow, to parent: NSWindow, over rectInParent: CGRect) {
        child.isReleasedWhenClosed = false
        child.setFrame(parent.convertToScreen(rectInParent), display: false)
        parent.addChildWindow(child, ordered: .above)
    }

    /// A Chromium page's own window: a plain (non-panel) borderless window.
    static func pageWindow() -> NSWindow {
        NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
    }

    /// One scroll event from `child` (a page or catcher window of `root`'s window) at the
    /// layout-window point `point`, through the layout's monitor routing. True: the layout took it.
    @discardableResult
    static func scroll(_ root: LayoutRootView, from child: NSWindow, at point: CGPoint, dx: Int32 = 0, dy: Int32 = 0,
                       phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase = .none,
                       units: CGScrollEventUnit = .pixel, command: Bool = false) -> Bool {
        guard let parent = root.window else {
            Issue.record("the layout is in no window")
            return false
        }
        let local = child.convertPoint(fromScreen: parent.convertPoint(toScreen: point))
        let event = event(dx: dx, dy: dy, phase: phase, momentum: momentum, units: units, command: command)
        return root.handleMonitoredScroll(event, from: child, at: local) == nil
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
            model = LayoutScrollModifierTests.columnsModel(modifier: modifier, focusFollowsMouse: focusFollowsMouse)
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
            LayoutScrollModifierTests.scroll(root, at: point, dx: dx, dy: dy, phase: phase, momentum: momentum, units: units, command: command)
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
        defer { w.window.closeAfterTest() }
        let before = try #require(w.root.frame(of: "p2"))
        #expect(w.gesture(at: try w.center("p2"), dx: -20) == 0, "the pane under the pointer gets every event")
        w.settle()
        #expect(w.root.frame(of: "p2") == before, "the strip did not move")
    }

    @Test func aCommandSidewaysSwipeOverTheSamePaneMovesTheStrip() throws {
        let w = Window(modifier: .command)
        defer { w.window.closeAfterTest() }
        let before = try #require(w.root.frame(of: "p2"))
        #expect(w.gesture(at: try w.center("p2"), dx: -20, commandAt: Set(0...7)) == 8, "the layout takes the gesture and its coast")
        w.settle()
        let after = try #require(w.root.frame(of: "p2"))
        #expect(after.minX < before.minX - 100, "the strip panned left: \(before) -> \(after)")
    }

    @Test func aPlainVerticalScrollOverAPaneInAnOverflowingColumnScrollsThePane() throws {
        let w = Window(modifier: .command)
        defer { w.window.closeAfterTest() }
        let before = try #require(w.root.frame(of: "top"))
        #expect(w.gesture(at: try w.center("top"), dy: -20) == 0)
        #expect(w.scroll(at: try w.center("top"), dy: -1, units: .line) == false, "a wheel notch too")
        w.settle()
        #expect(w.root.frame(of: "top") == before, "the rows did not move")
    }

    @Test func aCommandVerticalScrollOverAPaneScrollsTheRows() throws {
        let w = Window(modifier: .command)
        defer { w.window.closeAfterTest() }
        let before = try #require(w.root.frame(of: "top"))
        #expect(w.gesture(at: try w.center("top"), dy: -30, commandAt: Set(0...7)) == 8)
        w.settle()
        let after = try #require(w.root.frame(of: "top"))
        #expect(after.minY < before.minY - 100, "the rows scrolled up: \(before) -> \(after)")
        #expect(after.minX == before.minX, "the strip stayed")
    }

    @Test func aPlainVerticalScrollOverTheGapBetweenRowsScrollsTheRows() throws {
        let w = Window(modifier: .command)
        defer { w.window.closeAfterTest() }
        let before = try #require(w.root.frame(of: "top"))
        #expect(w.gesture(at: try w.rowGap(), dy: -30) == 8, "chrome with no pane under it is the layout's")
        w.settle()
        #expect(try #require(w.root.frame(of: "top")).minY < before.minY - 100)
    }

    @Test func pressingCommandMidGestureDoesNotTakeAPaneGesture() throws {
        let w = Window(modifier: .command)
        defer { w.window.closeAfterTest() }
        let before = try #require(w.root.frame(of: "p2"))
        #expect(w.gesture(at: try w.center("p2"), dx: -20, commandAt: Set(1...7)) == 0, "the first event gave it to the pane")
        w.settle()
        #expect(w.root.frame(of: "p2") == before)
    }

    @Test func releasingCommandMidGestureKeepsTheLayoutsGestureAndMomentum() throws {
        let w = Window(modifier: .command)
        defer { w.window.closeAfterTest() }
        let before = try #require(w.root.frame(of: "p2"))
        #expect(w.gesture(at: try w.center("p2"), dx: -20, commandAt: [0]) == 8, "the first event gave it to the layout")
        w.settle()
        #expect(try #require(w.root.frame(of: "p2")).minX < before.minX - 100)
    }

    /// A trackpad touch sends `mayBegin` before `began`: the touch decides, so Command pressed or
    /// released between them changes nothing (PL-motion-core review 2026-10-24).
    @Test func commandAtTheTouchDecidesEvenWhenReleasedBeforeTheGestureBegins() throws {
        let w = Window(modifier: .command)
        defer { w.window.closeAfterTest() }
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
        defer { w.window.closeAfterTest() }
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
        defer { w.window.closeAfterTest() }
        let before = try #require(w.root.frame(of: "p2"))
        #expect(w.gesture(at: try w.center("p2"), dy: -20, commandAt: Set(0...7)) == 8, "the layout takes the gesture and its coast")
        w.settle()
        let after = try #require(w.root.frame(of: "p2"))
        #expect(after.minX < before.minX - 100, "the strip panned: \(before) -> \(after)")
        #expect(after.minY == before.minY)
    }

    @Test func aWheelNotchDecidesPerNotch() throws {
        let w = Window(modifier: .command)
        defer { w.window.closeAfterTest() }
        let p2 = try w.center("p2")
        // A mouse's Shift+wheel arrives as a discrete horizontal notch.
        #expect(w.scroll(at: p2, dx: -1, units: .line) == false, "a plain notch is the pane's")
        #expect(w.scroll(at: p2, dx: -1, units: .line, command: true), "the next one, with Command, is the strip's")
        #expect(w.scroll(at: p2, dx: -1, units: .line) == false, "and the next plain one is the pane's again")
    }

    @Test func aCommandVerticalWheelOverAColumnWithoutRowsPansTheStrip() throws {
        let w = Window(modifier: .command)
        defer { w.window.closeAfterTest() }
        let before = try #require(w.root.frame(of: "p2"))
        #expect(w.scroll(at: try w.center("p2"), dy: -1, units: .line, command: true), "a one-wheel mouse still pans the columns")
        w.settle()
        #expect(try #require(w.root.frame(of: "p2")).minX < before.minX - 100)
    }

    @Test func aPlainScrollDoesNotMoveFocusWithFocusFollowsMouseOff() throws {
        let w = Window(modifier: .command, focusFollowsMouse: false)
        defer { w.window.closeAfterTest() }
        w.gesture(at: try w.center("p2"), dx: -20)
        w.gesture(at: try w.center("p2"), dy: -20)
        w.scroll(at: try w.center("p2"), dy: -1, units: .line)
        #expect(w.model.focusedPane == "top")
    }

    @Test func aPlainScrollFocusesThePaneWithFocusFollowsMouseOn() throws {
        let w = Window(modifier: .command, focusFollowsMouse: true)
        defer { w.window.closeAfterTest() }
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
        defer { window.closeAfterTest() }
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

    // MARK: one owner decision (review 1 of pl-scroll)

    /// Command held at the touch and released before the gesture begins: the layout owns the
    /// gesture from the touch, says so to the content inside it (the Chromium swipe asks this, not
    /// the modifier keys), keeps every event, its zero-delta start included, and gets its end.
    @Test func aCommandTouchOwnsTheWholeGestureAndTellsThePaneContent() throws {
        let w = Window(modifier: .command)
        defer { w.window.closeAfterTest() }
        let top = try w.center("top")
        let content = try #require(w.provider.views["top"])
        #expect(content.isDescendant(of: w.root))
        let before = try #require(w.root.frame(of: "p2"))
        #expect(w.scroll(at: top, phase: .mayBegin, command: true), "the pane never sees the touch of the layout's gesture")
        #expect(content.isScrollGestureTakenByEnclosingView, "decided at the touch")
        #expect(w.scroll(at: top, phase: .began), "nor its zero-delta start")
        for _ in 0..<3 { #expect(w.scroll(at: top, dx: -20, phase: .changed)) }
        #expect(content.isScrollGestureTakenByEnclosingView)
        let strip = try #require(w.root.screenViews["s"])
        #expect(strip.isUserScrolling)
        #expect(w.scroll(at: top, phase: .ended), "the layout gets the end")
        #expect(!strip.isUserScrolling, "the strip left its user scroll")
        #expect(!content.isScrollGestureTakenByEnclosingView, "between gestures nobody owns one")
        w.settle()
        #expect(try #require(w.root.frame(of: "p2")).minX < before.minX - 30, "the strip panned")
    }

    @Test func aPlainGestureOverAPaneIsNotTakenFromItsContent() throws {
        let w = Window(modifier: .command)
        defer { w.window.closeAfterTest() }
        let top = try w.center("top")
        let content = try #require(w.provider.views["top"])
        #expect(!w.scroll(at: top, phase: .mayBegin))
        #expect(!w.scroll(at: top, dx: -20, phase: .began))
        #expect(!content.isScrollGestureTakenByEnclosingView, "a Chromium page may swipe Back or Forward")
        #expect(!w.scroll(at: top, phase: .ended))
    }

    /// One column whose rows overflow and a strip that fits: Command + a sideways swipe stays the
    /// layout's (the pane never saw its start, and a web page must not go Back or Forward on it);
    /// the strip only rubber-bands and springs back.
    @Test func aCommandSwipeWithNothingToMoveItsWayStaysTheLayoutsAndMovesNothing() throws {
        let rows = [LayoutRow(id: "r1", height: 750, root: .leaf("top")),
                    LayoutRow(id: "r2", height: 750, root: .leaf("bottom"))]
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([
            LayoutColumn(id: "c1", width: 1, root: .split("x", axis: .vertical, ratio: 0.5, a: .leaf("top"), b: .leaf("bottom")),
                         rows: rows),
        ]))], activeScreenID: "s", focusedPane: "top")
        model.followsDesignMetrics = false
        model.rowsEnabledOverride = true
        model.scrollModifierOverride = .command
        let provider = Panes()
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        let frame = try #require(root.frame(of: "top"))
        let point = root.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        #expect(Self.scroll(root, at: point, dx: -20, phase: .began, command: true))
        #expect(root.ownsCurrentScrollGesture)
        for _ in 0..<3 { #expect(Self.scroll(root, at: point, dx: -20, phase: .changed)) }
        #expect(Self.scroll(root, at: point, phase: .ended))
        #expect(Self.scroll(root, at: point, dx: -10, momentum: .begin), "nor its coast")
        #expect(Self.scroll(root, at: point, momentum: .end))
        #expect(!root.ownsCurrentScrollGesture)
        for _ in 0..<600 { if !root.advanceFrame(1.0 / 120) { break } }
        #expect(root.frame(of: "top") == frame, "nothing moved")
    }

    /// Nothing to scroll at all (one column, no rows, the strip fits): Command + scroll is still the
    /// layout's, from a Chromium page's window as from the layout's own (a terminal), so a browser
    /// pane never goes Back or Forward on it and the strip only rubber-bands (Lawrence 2026-10-28,
    /// browser focus mode included; CommandScrollColumnsTests).
    @Test func aCommandSwipeWhereTheStripFitsIsTheLayoutsFromAPageWindowToo() throws {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([
            LayoutColumn(id: "c1", width: 1, root: .leaf("a")),
        ]))], activeScreenID: "s", focusedPane: "a")
        model.followsDesignMetrics = false
        model.scrollModifierOverride = .command
        let provider = Panes()
        let root = LayoutRootView(model: model, contentProvider: provider)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        let frame = try #require(root.frame(of: "a"))
        let point = root.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        let page = Self.pageWindow()
        Self.attach(page, to: window, over: root.convert(frame, to: nil))
        defer { window.removeChildWindow(page); page.close() }
        #expect(Self.scroll(root, from: page, at: point, phase: .mayBegin, command: true))
        #expect(Self.scroll(root, from: page, at: point, dx: -20, phase: .began, command: true))
        #expect(root.ownsCurrentScrollGesture)
        #expect(Self.scroll(root, from: page, at: point, dx: -20, phase: .changed, command: true))
        #expect(Self.scroll(root, from: page, at: point, phase: .ended, command: true))
        #expect(Self.scroll(root, at: point, dx: -20, phase: .began, command: true), "the layout's own window: the layout's")
        #expect(Self.scroll(root, at: point, phase: .ended, command: true))
    }

    /// Multi-view: two layouts in one window, each with its own monitor. Both see a touch; the one
    /// under the pointer takes the gesture and its end, so the other never sees them. The other's
    /// next gesture without a touch (a Magic Mouse) must still decide its owner.
    @Test func aTouchOverAnotherLayoutInTheWindowDoesNotStopThisOnesNextGestureDeciding() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        window.contentView = container
        let providers = [Panes(), Panes()]
        let roots = providers.map { LayoutRootView(model: Self.columnsModel(modifier: .command), contentProvider: $0) }
        for (index, root) in roots.enumerated() {
            root.frame = NSRect(x: CGFloat(index) * 500, y: 0, width: 500, height: 800)
            root.context.reduceMotionOverride = false
            container.addSubview(root)
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
        }
        let (a, b) = (roots[0], roots[1])
        // A plain vertical gesture over the gap between A's rows: A's chrome, so A takes it.
        let top = try #require(a.frame(of: "top")), middle = try #require(a.frame(of: "middle"))
        let gap = a.convert(CGPoint(x: top.midX, y: (top.maxY + middle.minY) / 2), to: nil)
        #expect(!Self.scroll(a, at: gap, phase: .mayBegin), "a plain touch goes on")
        #expect(!Self.scroll(b, at: gap, phase: .mayBegin), "B sees the touch too; it is not B's")
        #expect(Self.scroll(a, at: gap, dy: -30, phase: .began), "A takes the gesture: B never sees the rest")
        #expect(Self.scroll(a, at: gap, dy: -30, phase: .changed))
        #expect(Self.scroll(a, at: gap, phase: .ended))
        // Then a Command swipe over B with no touch first.
        let paneB = try #require(b.frame(of: "top"))
        let overB = b.convert(CGPoint(x: paneB.midX, y: paneB.midY), to: nil)
        #expect(b.bounds.contains(b.convert(overB, from: nil)))
        #expect(Self.scroll(b, at: overB, dx: -20, phase: .began, command: true), "B's own gesture decides at its began")
        #expect(Self.scroll(b, at: overB, dx: -20, phase: .changed))
        #expect(Self.scroll(b, at: overB, phase: .ended))
    }

    // MARK: page windows (scrollOrigin)

    /// The routing of a monitored scroll by the window it came from: this window's own point; a
    /// page window over a pane (a non-panel child), its point converted and flagged as a page's;
    /// the layout's divider catcher panel, its point converted, as the layout's own input; never
    /// another panel (a remote browser popup, an overlay) or another window's page.
    @Test func aScrollFromAPageOrCatcherWindowCountsOnlyForItsOwnWindow() throws {
        func window(_ rect: NSRect) -> NSWindow {
            let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            return window
        }
        let shell = window(NSRect(x: 0, y: 0, width: 1000, height: 800))
        let other = window(NSRect(x: 1200, y: 0, width: 600, height: 600))
        let page = window(NSRect(x: 100, y: 150, width: 400, height: 300))
        let otherPage = window(NSRect(x: 1300, y: 100, width: 200, height: 200))
        let popup = ContentChildPanel()
        popup.setFrame(NSRect(x: 120, y: 160, width: 100, height: 100), display: false)
        let panel = NSPanel(contentRect: NSRect(x: 130, y: 170, width: 100, height: 100), styleMask: [.borderless],
                            backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        let catcher = DividerMousePanel()
        catcher.setFrame(NSRect(x: 300, y: 200, width: 20, height: 100), display: false)
        shell.addChildWindow(page, ordered: .above)
        shell.addChildWindow(catcher, ordered: .above)
        shell.addChildWindow(popup, ordered: .above)
        shell.addChildWindow(panel, ordered: .above)
        other.addChildWindow(otherPage, ordered: .above)
        defer {
            for child in [page, popup, panel, catcher] { shell.removeChildWindow(child) }
            other.removeChildWindow(otherPage)
            for each in [shell, other, page, otherPage, popup, panel, catcher] { each.close() }
        }
        let point = NSPoint(x: 10, y: 20)
        typealias Origin = LayoutRootView.ScrollOrigin
        #expect(LayoutRootView.scrollOrigin(of: shell, at: point, in: shell)
                == Origin(locationInWindow: point, isPageWindow: false))
        let converted = NSPoint(x: page.frame.minX - shell.frame.minX + 10, y: page.frame.minY - shell.frame.minY + 20)
        #expect(converted != point, "the page sits at an offset in the shell")
        #expect(LayoutRootView.scrollOrigin(of: page, at: point, in: shell)
                == Origin(locationInWindow: converted, isPageWindow: true), "a page window's point, in the shell window")
        let inCatcher = NSPoint(x: catcher.frame.minX - shell.frame.minX + 10, y: catcher.frame.minY - shell.frame.minY + 20)
        #expect(LayoutRootView.scrollOrigin(of: catcher, at: point, in: shell)
                == Origin(locationInWindow: inCatcher, isPageWindow: false), "a divider catcher is the layout's own input")
        #expect(LayoutRootView.scrollOrigin(of: otherPage, at: point, in: shell) == nil, "another window's page")
        #expect(LayoutRootView.scrollOrigin(of: other, at: point, in: shell) == nil, "another window")
        #expect(LayoutRootView.scrollOrigin(of: popup, at: point, in: shell) == nil, "a remote browser popup scrolls its list")
        #expect(LayoutRootView.scrollOrigin(of: panel, at: point, in: shell) == nil, "an overlay panel")
        #expect(LayoutRootView.scrollOrigin(of: nil, at: point, in: shell) == nil)
        #expect(LayoutRootView.scrollOrigin(of: page, at: point, in: nil) == nil)
    }

    /// From a page window only Command + scroll is the layout's: a plain scroll there is the
    /// page's even where the layout's own point would be chrome.
    @Test func aPlainScrollFromAPageWindowIsThePagesEvenOverChrome() throws {
        let w = Window(modifier: .command)
        defer { w.window.closeAfterTest() }
        let gap = try w.rowGap()
        func event(_ phase: CGScrollPhase, dy: Int32 = 0, command: Bool = false) -> NSEvent {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: 0, wheel3: 0)!
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            if command { cg.flags = .maskCommand }
            return NSEvent(cgEvent: cg)!
        }
        /// A began, a change and an end from one origin; true: the layout took all three.
        func gesture(fromPageWindow: Bool, command: Bool) -> [Bool] {
            [event(.began, dy: -30, command: command), event(.changed, dy: -30), event(.ended)].map {
                w.root.handleScrollEvent($0, at: gap, fromPageWindow: fromPageWindow) == nil
            }
        }
        #expect(gesture(fromPageWindow: true, command: false) == [false, false, false], "a plain scroll from a page is the page's")
        #expect(gesture(fromPageWindow: false, command: false) == [true, true, true], "the same point in the layout's window is chrome")
        #expect(gesture(fromPageWindow: true, command: true) == [true, true, true], "Command + scroll from a page is the layout's")
    }

    // MARK: review 2 of pl-scroll

    /// Two half columns on a 1200 pt window, so the strip fits: the first holds the chain
    /// p1 | p2 | p3, too wide for its column with `layout.scrollAreas` on, so it is a scroll area;
    /// the second holds `q` alone.
    final class AreaWindow {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)

        init() throws {
            let chain: SplitNode = .split("s1", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p1"),
                                          b: .split("s2", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([
                LayoutColumn(id: "c1", width: 0.5, root: chain),
                LayoutColumn(id: "c2", width: 0.5, root: .leaf("q")),
            ]))], activeScreenID: "s", focusedPane: "q")
            model.followsDesignMetrics = false
            model.baseStyle.minimumPaneContentSize = CGSize(width: 300, height: 64)
            model.baseStyle.scrollAreasEnabled = true
            model.scrollModifierOverride = .command
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            let strip = try #require(root.screenViews["s"])
            try #require(!strip.areaScrolls.isEmpty, "the first column is a scroll area")
            try #require(!strip.acceptsHorizontalScroll, "the strip fits")
        }

        func center(_ pane: PaneID) throws -> CGPoint {
            let frame = try #require(root.frame(of: pane))
            return root.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        }
    }

    /// Over a page outside every scroll area, where the strip fits and no rows overflow, a Command
    /// gesture is still the layout's (the strip rubber-bands), as the wheel is: a browser pane never
    /// swipes Back or Forward on it (Lawrence 2026-10-28).
    @Test func aCommandGestureOutsideEveryScrollAreaIsTheLayoutsFromAPageWindowToo() throws {
        let w = try AreaWindow()
        defer { w.window.closeAfterTest() }
        let q = try w.center("q")
        let page = Self.pageWindow()
        Self.attach(page, to: w.window, over: w.root.convert(try #require(w.root.frame(of: "q")), to: nil))
        defer { w.window.removeChildWindow(page); page.close() }
        func scroll(at point: CGPoint, dx: Int32 = 0, dy: Int32 = 0, phase: CGScrollPhase? = nil,
                    units: CGScrollEventUnit = .pixel, command: Bool) -> Bool {
            Self.scroll(w.root, from: page, at: point, dx: dx, dy: dy, phase: phase, units: units, command: command)
        }
        #expect(scroll(at: q, phase: .mayBegin, command: true), "the page never sees the touch")
        #expect(w.root.ownsCurrentScrollGesture)
        #expect(scroll(at: q, dx: -20, phase: .began, command: true))
        #expect(scroll(at: q, dx: -20, phase: .changed, command: true))
        #expect(scroll(at: q, phase: .ended, command: true))
        #expect(scroll(at: q, dy: -30, phase: .began, command: true), "up and down alike")
        #expect(scroll(at: q, phase: .ended, command: true))
        #expect(scroll(at: q, dx: -1, units: .line, command: true), "the wheel agrees")
        #expect(!scroll(at: q, dx: -1, units: .line, command: false), "a plain notch is the page's")
        // Over the area itself, which can move toward its end, Command + scroll is the layout's.
        let p1 = try w.center("p1")
        #expect(Self.scroll(w.root, at: p1, dx: -20, phase: .began, command: true))
        #expect(Self.scroll(w.root, at: p1, dx: -20, phase: .changed, command: true))
        #expect(Self.scroll(w.root, at: p1, phase: .ended, command: true))
    }

    /// While a Chromium page shows, a divider's hit area is a catcher panel above the pages
    /// (`DividerMouseCatchers`). A scroll there is the layout's input, as over the same gap with no
    /// page: a plain scroll over the gap between rows scrolls the rows.
    @Test func aScrollOverADividerCatcherPanelIsTheLayouts() throws {
        let w = Window(modifier: .command)
        defer { w.window.closeAfterTest() }
        let gap = try w.rowGap()
        let top = try #require(w.root.frame(of: "top"))
        let page = Self.pageWindow(), catcher = DividerMousePanel()
        Self.attach(page, to: w.window, over: w.root.convert(top, to: nil))
        Self.attach(catcher, to: w.window, over: CGRect(x: gap.x - 40, y: gap.y - 12, width: 80, height: 24))
        defer {
            for child in [page, catcher] { w.window.removeChildWindow(child); child.close() }
        }
        #expect(Self.scroll(w.root, from: catcher, at: gap, dy: -30, phase: .began), "the gap's plain scroll is the layout's")
        for _ in 0..<3 { #expect(Self.scroll(w.root, from: catcher, at: gap, dy: -30, phase: .changed)) }
        #expect(Self.scroll(w.root, from: catcher, at: gap, phase: .ended))
        w.settle()
        #expect(try #require(w.root.frame(of: "top")).minY < top.minY - 30, "the rows scrolled")
        // Under `none` the catcher is the layout's too: its gap scrolls the rows.
        let none = Window(modifier: .noModifier)
        defer { none.window.closeAfterTest() }
        let noneGap = try none.rowGap(), noneTop = try #require(none.root.frame(of: "top"))
        let noneCatcher = DividerMousePanel()
        Self.attach(noneCatcher, to: none.window, over: CGRect(x: noneGap.x - 40, y: noneGap.y - 12, width: 80, height: 24))
        defer { none.window.removeChildWindow(noneCatcher); noneCatcher.close() }
        #expect(Self.scroll(none.root, from: noneCatcher, at: noneGap, dy: -30, phase: .began))
        #expect(Self.scroll(none.root, from: noneCatcher, at: noneGap, dy: -30, phase: .changed))
        #expect(Self.scroll(none.root, from: noneCatcher, at: noneGap, phase: .ended))
        none.settle()
        #expect(try #require(none.root.frame(of: "top")).minY < noneTop.minY - 10)
    }

    /// A canvas screen of two panes, `a` on the left and `b` on the right, with empty canvas
    /// between them, on a 1200 x 700 window.
    final class CanvasWindow {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)

        init(modifier: LayoutScrollModifier) throws {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(
                .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b"))))], activeScreenID: "s", focusedPane: "a")
            model.followsDesignMetrics = false
            model.scrollModifierOverride = modifier
            root = LayoutRootView(model: model, contentProvider: provider)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            let seed: [PaneID: CGRect] = ["a": CGRect(x: 0, y: 0, width: 400, height: 700),
                                          "b": CGRect(x: 800, y: 0, width: 400, height: 700)]
            try #require(model.toggleCanvas(seed: seed, viewport: CGSize(width: 1200, height: 700)))
            root.syncWithModel()
            let strip = try #require(root.screenViews["s"])
            try #require(strip.pane(at: strip.convert(emptyCanvas, from: nil)) == nil, "empty canvas between the panes")
        }

        /// A window point over empty canvas.
        var emptyCanvas: CGPoint { root.convert(CGPoint(x: 600, y: 350), to: nil) }
    }

    /// A canvas pan owns its gesture until the gesture ends, not after: its coast still pans,
    /// and after a pan with no coast the layout owns nothing, so the next gesture over a Chromium
    /// page (whose swipe asks the layout) is the page's, under either modifier.
    @Test(arguments: [LayoutScrollModifier.command, .noModifier])
    func aCanvasPanOwnsItsGestureOnlyUntilItEnds(modifier: LayoutScrollModifier) throws {
        let w = try CanvasWindow(modifier: modifier)
        defer { w.window.closeAfterTest() }
        let point = w.emptyCanvas
        let start = try #require(w.root.frame(of: "a"))
        #expect(Self.scroll(w.root, at: point, dx: -20, phase: .began))
        #expect(w.root.ownsCurrentScrollGesture)
        #expect(Self.scroll(w.root, at: point, dx: -20, phase: .changed))
        #expect(Self.scroll(w.root, at: point, phase: .ended))
        #expect(!w.root.ownsCurrentScrollGesture, "the gesture ended")
        let ended = try #require(w.root.frame(of: "a"))
        #expect(ended.minX < start.minX, "the canvas panned")
        #expect(Self.scroll(w.root, at: point, dx: -10, momentum: .begin), "its coast is the canvas's")
        #expect(Self.scroll(w.root, at: point, momentum: .end))
        #expect(try #require(w.root.frame(of: "a")).minX < ended.minX, "the coast panned")
        // A pan lifted with no coast.
        #expect(Self.scroll(w.root, at: point, dx: -20, phase: .began))
        #expect(Self.scroll(w.root, at: point, phase: .ended))
        #expect(!w.root.ownsCurrentScrollGesture, "a slow lift leaves no gesture owned")
        // Then a plain gesture over a Chromium page on `b`.
        let bFrame = try #require(w.root.frame(of: "b"))
        let page = Self.pageWindow()
        Self.attach(page, to: w.window, over: w.root.convert(bFrame, to: nil))
        defer { w.window.removeChildWindow(page); page.close() }
        let overB = w.root.convert(CGPoint(x: bFrame.midX, y: bFrame.midY), to: nil)
        #expect(!Self.scroll(w.root, from: page, at: overB, dx: -20, phase: .began))
        #expect(!Self.scroll(w.root, from: page, at: overB, dx: -20, phase: .changed))
        #expect(!w.root.ownsCurrentScrollGesture, "the page's gesture: its swipe may go Back or Forward")
        #expect(!Self.scroll(w.root, from: page, at: overB, phase: .ended))
    }

    /// From a page window a plain scroll is the page's on a canvas too, even where the layout's
    /// point is empty canvas (a page window trailing its pane during a pan or zoom); Command +
    /// scroll from it pans the canvas.
    @Test func aPlainScrollFromAPageWindowIsThePagesOverEmptyCanvas() throws {
        let w = try CanvasWindow(modifier: .command)
        defer { w.window.closeAfterTest() }
        let point = w.emptyCanvas
        let start = try #require(w.root.frame(of: "a"))
        let fromPage = { (event: NSEvent) in w.root.handleScrollEvent(event, at: point, fromPageWindow: true) == nil }
        #expect(!fromPage(Self.event(dx: -20, phase: .began)), "a plain gesture from a page is the page's")
        #expect(!fromPage(Self.event(dx: -20, phase: .changed)))
        #expect(!fromPage(Self.event(phase: .ended)))
        #expect(!fromPage(Self.event(dx: -1, units: .line)), "a plain wheel notch from a page is the page's")
        #expect(w.root.frame(of: "a") == start, "the canvas did not move")
        #expect(fromPage(Self.event(dx: -20, phase: .began, command: true)), "Command + scroll from a page pans the canvas")
        #expect(fromPage(Self.event(dx: -20, phase: .changed)))
        #expect(fromPage(Self.event(phase: .ended)))
        #expect(try #require(w.root.frame(of: "a")).minX < start.minX)
    }

    /// Under `none`, a strip pan that slides a Chromium page under the still pointer keeps its
    /// events: the rest of the gesture comes from the page window, and its end must still end
    /// the strip's user scroll (else the strip stays mid-gesture and the layout keeps owning a
    /// gesture that is over).
    @Test func noneKeepsAStripPanWhoseRestComesFromAPageWindow() throws {
        let w = Window(modifier: .noModifier)
        defer { w.window.closeAfterTest() }
        let p2 = try w.center("p2")
        let strip = try #require(w.root.screenViews["s"])
        #expect(w.scroll(at: p2, dx: -20, phase: .began))
        #expect(w.scroll(at: p2, dx: -20, phase: .changed))
        #expect(strip.isUserScrolling)
        let page = Self.pageWindow()
        Self.attach(page, to: w.window, over: CGRect(x: p2.x - 50, y: p2.y - 50, width: 100, height: 100))
        defer { w.window.removeChildWindow(page); page.close() }
        #expect(Self.scroll(w.root, from: page, at: p2, dx: -20, phase: .changed), "the strip's gesture, now over a page")
        #expect(Self.scroll(w.root, from: page, at: p2, phase: .ended))
        #expect(!strip.isUserScrolling, "the strip left its user scroll")
        #expect(!w.root.ownsCurrentScrollGesture)
        #expect(Self.scroll(w.root, from: page, at: p2, dx: -10, momentum: .begin), "the strip's spring owns the coast")
        #expect(Self.scroll(w.root, from: page, at: p2, momentum: .end))
        // A new plain gesture from the page stays the page's under `none`, as before.
        #expect(!Self.scroll(w.root, from: page, at: p2, dx: -20, phase: .began))
        #expect(!Self.scroll(w.root, from: page, at: p2, dx: -20, phase: .changed))
        #expect(!w.root.ownsCurrentScrollGesture)
        #expect(!Self.scroll(w.root, from: page, at: p2, phase: .ended))
    }

    /// The seam CEFSwipeNavigation reads: a Chromium pane's `CEFHostView`, inside the pane content
    /// the layout hosts, reports a gesture the layout claimed at its touch, and only that one.
    @Test func aChromiumHostViewInAPaneSeesTheLayoutsClaim() throws {
        let provider = Panes()
        provider.make = { _ in
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            content.addSubview(CEFHostView(frame: content.bounds))
            return content
        }
        let model = Self.columnsModel(modifier: .command)
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        let host = try #require(provider.views["top"]?.subviews.first as? CEFHostView)
        #expect(host.isDescendant(of: root))
        let frame = try #require(root.frame(of: "top"))
        let point = root.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        #expect(!Self.scroll(root, at: point, phase: .mayBegin))
        #expect(!Self.scroll(root, at: point, dx: -20, phase: .began))
        #expect(!host.isScrollGestureTakenByEnclosingView, "a plain gesture: the page may swipe")
        #expect(!Self.scroll(root, at: point, phase: .ended))
        #expect(Self.scroll(root, at: point, phase: .mayBegin, command: true))
        #expect(Self.scroll(root, at: point, phase: .began))
        #expect(Self.scroll(root, at: point, dx: -20, phase: .changed))
        #expect(host.isScrollGestureTakenByEnclosingView, "the layout's gesture: no swipe")
        #expect(Self.scroll(root, at: point, phase: .ended))
        #expect(!host.isScrollGestureTakenByEnclosingView)
    }

    // MARK: none (the rule before)

    @Test func noneLetsAPlainSidewaysSwipeOverAPaneMoveTheStrip() throws {
        let w = Window(modifier: .noModifier)
        defer { w.window.closeAfterTest() }
        let before = try #require(w.root.frame(of: "p2"))
        #expect(w.gesture(at: try w.center("p2"), dx: -20) == 8)
        w.settle()
        #expect(try #require(w.root.frame(of: "p2")).minX < before.minX - 100)
    }

    @Test func noneKeepsAPlainVerticalScrollOverAPaneWithThePaneAndCommandScrollsRows() throws {
        let w = Window(modifier: .noModifier)
        defer { w.window.closeAfterTest() }
        let before = try #require(w.root.frame(of: "top"))
        #expect(w.gesture(at: try w.center("top"), dy: -30) == 0)
        #expect(w.gesture(at: try w.center("top"), dy: -30, commandAt: Set(0...7)) == 8)
        w.settle()
        #expect(try #require(w.root.frame(of: "top")).minY < before.minY - 100)
    }

    @Test func noneKeepsAPlainVerticalWheelOverAColumnWithoutRowsWithThePane() throws {
        let w = Window(modifier: .noModifier)
        defer { w.window.closeAfterTest() }
        #expect(w.scroll(at: try w.center("p2"), dy: -1, units: .line, command: true) == false)
    }
}
