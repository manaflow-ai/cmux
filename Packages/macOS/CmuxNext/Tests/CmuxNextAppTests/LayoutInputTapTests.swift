import AppKit
import CmuxNextInput
@testable import CmuxNextLayout
import CmuxNextWakeups
import Testing

/// The layout root's routing on the app's input tap: a live root holds one intercept for scrolls,
/// trackpad gestures and buttons at the layout's order; a hidden or windowless root holds none; a press through
/// the tap focuses the pane under it, and the root never stops the press; a scroll the layout takes is consumed
/// there, and the intercepts before it (a popup) go first.
@MainActor @Suite(.serialized) struct LayoutInputTapTests {
    final class Harness {
        let tap = InputEventTap()
        let provider = LayoutScrollModifierTests.Panes()
        let model = LayoutScrollModifierTests.columnsModel(modifier: .command)
        let root: LayoutRootView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)

        init() {
            _ = NSApplication.shared
            root = LayoutRootView(model: model, contentProvider: provider, input: tap, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            root.context.reduceMotionOverride = false
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
        }

        func close() { window.orderOut(nil) }

        func intercepts(_ eventClass: InputEventClass) -> Int { tap.subscriberCount(eventClass, stage: .intercept) }

        /// `event` through the tap's three stages; true when an intercept consumed it.
        func dispatch(_ event: NSEvent) -> Bool {
            var consumed = false
            tap.dispatching {
                tap.deliverObserve(event)
                consumed = tap.deliverIntercepts(event) == .consume
                tap.deliverAfterDispatch(event)
            }
            return consumed
        }

        /// A sideways trackpad scroll in `phase` at `point` (window coordinates) that names the harness's window,
        /// as the window server sends one, so it routes the way a real scroll does (`event.window`).
        func scroll(at point: CGPoint, dx: Int32, phase: CGScrollPhase, command: Bool) throws -> NSEvent {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            if command { cg.flags = .maskCommand }
            // Quartz's global coordinates start at the primary display's top left.
            let screenPoint = window.convertPoint(toScreen: point)
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            cg.location = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            let event = try #require(NSEvent(cgEvent: cg))
            try #require(event.window === window, "the scroll does not name the layout's window")
            try #require(abs(event.locationInWindow.x - point.x) < 1 && abs(event.locationInWindow.y - point.y) < 1,
                         "the scroll is at \(event.locationInWindow), not \(point)")
            return event
        }

        /// A left press at `point` (window coordinates) in the harness's window.
        func press(at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                            clickCount: 1, pressure: 1))
        }

        /// The center of `pane` in window coordinates.
        func center(_ pane: PaneID) throws -> CGPoint {
            let frame = try #require(root.frame(of: pane))
            return root.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        }

        func settle() { for _ in 0..<600 { if !root.advanceFrame(1.0 / 120) { break } } }
    }

    @Test func aLiveRootHoldsOneInterceptForScrollsGesturesAndButtons() {
        let harness = Harness()
        defer { harness.close() }
        #expect(harness.root.isLive)
        #expect(harness.intercepts(.scroll) == 1)
        #expect(harness.intercepts(.gesture) == 1)
        #expect(harness.intercepts(.button) == 1)
        #expect(harness.intercepts(.key) == 0 && harness.intercepts(.pointerMove) == 0 && harness.intercepts(.flags) == 0)
        #expect(harness.tap.subscriberCount(.scroll, stage: .observe) == 0, "the layout's routing is an intercept, not an observer")
    }

    @Test func aHiddenOrWindowlessRootHoldsNoIntercept() {
        let harness = Harness()
        defer { harness.close() }
        harness.root.isHidden = true
        #expect(!harness.root.isLive)
        #expect(harness.intercepts(.scroll) == 0 && harness.intercepts(.button) == 0 && harness.intercepts(.gesture) == 0)
        harness.root.isHidden = false
        #expect(harness.intercepts(.scroll) == 1, "a shown root subscribes again")
        harness.window.contentView = nil
        #expect(harness.intercepts(.scroll) == 0 && harness.intercepts(.button) == 0 && harness.intercepts(.gesture) == 0)
    }

    @Test func aPressThroughTheTapFocusesThePaneUnderItAndGoesOn() throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(harness.model.focusedPane == "top")
        var later = 0
        let standard = harness.tap.subscribe(class: .button, phase: .intercept(order: .standard)) { _ -> InputEventTap.InterceptResult in
            later += 1
            return .pass
        }
        defer { standard.cancel() }
        let press = try harness.press(at: harness.center("p2"))
        #expect(!harness.dispatch(press), "the layout consumed a press")
        #expect(harness.model.focusedPane == "p2", "the press did not focus the pane under it")
        #expect(later == 1, "an intercept after the layout's did not get the press it passed")
    }

    /// A Command sideways scroll over a pane is the layout's under `command`: its intercept consumes every event of
    /// the gesture (so AppKit and later intercepts never get them) and the strip pans.
    @Test(.enabled(if: !NSScreen.screens.isEmpty, "a windowed scroll's point needs a display"))
    func aCommandSidewaysScrollThroughTheTapIsConsumedAndPansTheStrip() throws {
        let harness = Harness()
        defer { harness.close() }
        var later = 0
        let standard = harness.tap.subscribe(class: .scroll, phase: .intercept(order: .standard)) { _ -> InputEventTap.InterceptResult in
            later += 1
            return .pass
        }
        defer { standard.cancel() }
        let point = try harness.center("p2")
        let before = try #require(harness.root.frame(of: "p2"))
        let began = try harness.scroll(at: point, dx: -20, phase: .began, command: true)
        #expect(harness.dispatch(began), "the layout did not consume the gesture's first event")
        for _ in 0..<3 {
            let changed = try harness.scroll(at: point, dx: -20, phase: .changed, command: true)
            #expect(harness.dispatch(changed))
        }
        let ended = try harness.scroll(at: point, dx: 0, phase: .ended, command: true)
        #expect(harness.dispatch(ended))
        #expect(later == 0, "an intercept after the layout's got \(later) events the layout consumed")
        harness.settle()
        let after = try #require(harness.root.frame(of: "p2"))
        #expect(after.minX < before.minX - 30, "the strip did not pan: \(before) -> \(after)")
    }

    /// A plain sideways scroll over a pane is the pane's: the layout's intercept passes it on.
    @Test(.enabled(if: !NSScreen.screens.isEmpty, "a windowed scroll's point needs a display"))
    func aPlainSidewaysScrollThroughTheTapGoesOn() throws {
        let harness = Harness()
        defer { harness.close() }
        let point = try harness.center("p2")
        let before = try #require(harness.root.frame(of: "p2"))
        let began = try harness.scroll(at: point, dx: -20, phase: .began, command: false)
        #expect(!harness.dispatch(began), "the layout consumed a plain scroll over a pane")
        let ended = try harness.scroll(at: point, dx: 0, phase: .ended, command: false)
        #expect(!harness.dispatch(ended))
        harness.settle()
        #expect(harness.root.frame(of: "p2") == before, "the strip moved")
    }

    /// A popup's intercept runs before the layout's: a press the popup consumes never reaches the layout.
    @Test func aPopupInterceptThatConsumesAPressKeepsItFromTheLayout() throws {
        let harness = Harness()
        defer { harness.close() }
        var popupHeard = 0
        let popup = harness.tap.subscribe(class: .button, phase: .intercept(order: .popup)) { _ -> InputEventTap.InterceptResult in
            popupHeard += 1
            return .consume
        }
        defer { popup.cancel() }
        let press = try harness.press(at: harness.center("p2"))
        #expect(harness.dispatch(press))
        #expect(popupHeard == 1)
        #expect(harness.model.focusedPane == "top", "the layout routed a press the popup consumed before it")
    }

    @Test func aScrollWithNoWindowGoesOn() throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(!harness.dispatch(LayoutScrollModifierTests.event(dx: -20, phase: .began, command: true)),
                "the layout took a scroll that is not its window's")
    }
}
