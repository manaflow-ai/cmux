import AppKit
import CmuxNextInput
@testable import CmuxNextLayout
import Testing

/// The layout root's routing on the app's input tap (p04-input-019): a live root holds one intercept for scrolls,
/// trackpad gestures and buttons at the layout's order; a hidden or windowless root holds none; a press through
/// the tap focuses the pane under it, and the root never stops the press.
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
            root = LayoutRootView(model: model, contentProvider: provider, input: tap)
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
        let frame = try #require(harness.root.frame(of: "p2"))
        let point = harness.root.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        let press = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1,
                                                    windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 1))
        #expect(!harness.dispatch(press), "the layout consumed a press")
        #expect(harness.model.focusedPane == "p2", "the press did not focus the pane under it")
    }

    @Test func aScrollWithNoWindowGoesOn() throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(!harness.dispatch(LayoutScrollModifierTests.event(dx: -20, phase: .began, command: true)),
                "the layout took a scroll that is not its window's")
    }
}
