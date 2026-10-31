import AppKit
import CmuxNextLayout
import CmuxNextTestSupport
import CoreGraphics
import Testing

/// `layout.focusFollowsMouse`: off by default, so hovering or scrolling another pane keeps focus
/// where the person types (the user, Oct 20). Turned on, the pointer entering a pane or a scroll
/// over it focuses it, the same for every pane kind, since the layout routes it before the pane's
/// own view sees it. Momentum, a pane the layout scrolls itself, recent typing, a held mouse
/// button and a background window leave focus where it was.
@MainActor
@Suite(.closesItsWindows)
struct FocusFollowsMouseTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Window {
        let provider = Panes()
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(
            .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))))], activeScreenID: "s", focusedPane: "p1")
        let root: LayoutRootView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        var secondsSinceKeyDown: TimeInterval = 60
        var windowIsKey = true
        var mouseButtonsDown = false

        init(focusOnScroll: Bool? = true) {
            var signals = ScrollFocusSignals()
            let box = Box()
            signals.secondsSinceKeyDown = { box.window?.secondsSinceKeyDown ?? 60 }
            signals.windowIsKey = { _ in box.window?.windowIsKey ?? true }
            signals.mouseButtonsDown = { box.window?.mouseButtonsDown ?? false }
            model.focusFollowsMouseOverride = focusOnScroll
            root = LayoutRootView(model: model, contentProvider: provider, scrollFocusSignals: signals)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            box.window = self
        }

        final class Box { weak var window: Window? }

        func center(_ pane: PaneID) throws -> CGPoint {
            let frame = try #require(root.frame(of: pane))
            return root.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        }

        /// One scroll event over `point` (window coordinates), as the layout's monitor sees it.
        @discardableResult
        func scroll(at point: CGPoint, dy: Int32 = -12, phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase = .none,
                    units: CGScrollEventUnit = .pixel) -> Bool {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: dy, wheel2: 0, wheel3: 0)!
            if let phase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
            let event = NSEvent(cgEvent: cg)!
            return root.handleScroll(event, locationInWindow: point)
        }

        /// The pointer moving to `point` (window coordinates).
        @discardableResult
        func hover(at point: CGPoint) -> PaneID? { root.focusPaneForPointerHover(at: point) }

        /// A trackpad gesture over `point`: began, changes, ended.
        func gesture(at point: CGPoint) {
            scroll(at: point, phase: .began)
            scroll(at: point, phase: .changed)
            scroll(at: point, dy: 0, phase: .ended)
        }
    }

    @Test func aMouseWheelOverAnotherPaneFocusesIt() throws {
        let w = Window()
        defer { w.window.closeAfterTest() }
        #expect(w.scroll(at: try w.center("p2"), dy: -1, units: .line) == false, "the pane still gets the scroll")
        #expect(w.model.focusedPane == "p2")
        #expect(w.model.lastFocusSource == .scroll)
    }

    @Test func aTrackpadScrollOverAnotherPaneFocusesItAtItsStart() throws {
        let w = Window()
        defer { w.window.closeAfterTest() }
        let p2 = try w.center("p2")
        #expect(w.scroll(at: p2, phase: .began) == false, "the pane still gets the scroll")
        #expect(w.model.focusedPane == "p2")
    }

    @Test func momentumFromAnEarlierGestureDoesNotStealFocus() throws {
        let w = Window()
        defer { w.window.closeAfterTest() }
        // A flick in p1 ends; its coast passes over p2.
        w.gesture(at: try w.center("p1"))
        let p2 = try w.center("p2")
        w.scroll(at: p2, momentum: .begin)
        w.scroll(at: p2, momentum: .continuous)
        w.scroll(at: p2, dy: 0, momentum: .end)
        #expect(w.model.focusedPane == "p1")
    }

    @Test func recentTypingKeepsFocus() throws {
        let w = Window()
        defer { w.window.closeAfterTest() }
        w.secondsSinceKeyDown = 0.3
        w.gesture(at: try w.center("p2"))
        w.scroll(at: try w.center("p2"), dy: -1, units: .line)
        #expect(w.model.focusedPane == "p1")
        // A second later typing no longer holds focus.
        w.secondsSinceKeyDown = 1.5
        w.gesture(at: try w.center("p2"))
        #expect(w.model.focusedPane == "p2")
    }

    @Test func aBackgroundWindowKeepsItsFocus() throws {
        let w = Window()
        defer { w.window.closeAfterTest() }
        w.windowIsKey = false
        w.gesture(at: try w.center("p2"))
        #expect(w.model.focusedPane == "p1")
    }

    /// The default (no override, no cmux.json key): scrolling another pane keeps focus where the
    /// person is typing (the user, Oct 20).
    @Test func byDefaultAScrollOverAnotherPaneKeepsFocus() throws {
        let w = Window(focusOnScroll: nil)
        defer { w.window.closeAfterTest() }
        w.gesture(at: try w.center("p2"))
        w.scroll(at: try w.center("p2"), dy: -1, units: .line)
        #expect(w.model.focusedPane == "p1")
    }

    @Test func byDefaultHoveringAnotherPaneKeepsFocus() throws {
        let w = Window(focusOnScroll: nil)
        defer { w.window.closeAfterTest() }
        w.hover(at: try w.center("p2"))
        #expect(w.model.focusedPane == "p1")
    }

    @Test func turnedOnTheSettingFocusesAPaneThePointerEnters() throws {
        let w = Window()
        defer { w.window.closeAfterTest() }
        w.hover(at: try w.center("p1"))
        #expect(w.hover(at: try w.center("p2")) == "p2")
        #expect(w.model.focusedPane == "p2")
        #expect(w.model.lastFocusSource == .pointer)
    }

    @Test func hoverDoesNotUndoAKeyboardMoveInsideTheSamePane() throws {
        let w = Window()
        defer { w.window.closeAfterTest() }
        let p2 = try w.center("p2")
        w.hover(at: p2)
        #expect(w.model.focusedPane == "p2")
        w.model.focus("p1", source: .keyboard)
        // The pointer twitches but stays in p2: focus stays where the keyboard put it.
        w.hover(at: CGPoint(x: p2.x + 3, y: p2.y + 2))
        #expect(w.model.focusedPane == "p1")
    }

    @Test func hoverWhileTypingOrDraggingOrInABackgroundWindowKeepsFocus() throws {
        let w = Window()
        defer { w.window.closeAfterTest() }
        let p1 = try w.center("p1"), p2 = try w.center("p2")
        w.secondsSinceKeyDown = 0.3
        w.hover(at: p2)
        #expect(w.model.focusedPane == "p1")
        w.hover(at: p1)
        w.secondsSinceKeyDown = 60
        w.mouseButtonsDown = true
        w.hover(at: p2)
        #expect(w.model.focusedPane == "p1")
        w.hover(at: p1)
        w.mouseButtonsDown = false
        w.windowIsKey = false
        w.hover(at: p2)
        #expect(w.model.focusedPane == "p1")
    }

    @Test func theSettingTurnedOffKeepsFocus() throws {
        let w = Window(focusOnScroll: false)
        defer { w.window.closeAfterTest() }
        w.gesture(at: try w.center("p2"))
        w.scroll(at: try w.center("p2"), dy: -1, units: .line)
        w.hover(at: try w.center("p2"))
        #expect(w.model.focusedPane == "p1")
    }

    @Test func scrollingTheFocusedPaneChangesNothing() throws {
        let w = Window()
        defer { w.window.closeAfterTest() }
        let before = w.model.lastFocusSource
        w.gesture(at: try w.center("p1"))
        #expect(w.model.focusedPane == "p1")
        #expect(w.model.lastFocusSource == before, "a scroll over the focused pane keeps a keyboard focus ring")
    }
}
