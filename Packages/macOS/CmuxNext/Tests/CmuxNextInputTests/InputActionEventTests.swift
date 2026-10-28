import AppKit
@testable import CmuxNextInput
import CmuxNextInputCore
import Testing

/// The event an action answers: the event being dispatched, or a menu or control's
/// tracking event while that dispatch or the menu's action send runs (Option pressed while a menu is
/// open), never an event AppKit keeps as its current one after the loop or dispatch ended (a CLI or
/// socket run reads nil).
@MainActor @Suite(.serialized)
struct InputActionEventTests {
    /// A tap whose dispatch and AppKit current event the test sets, fed as `CmuxApplication.sendEvent` feeds it.
    @MainActor final class Rig {
        let tap = InputEventTap()
        var dispatched: NSEvent?
        var current: NSEvent?

        init() {
            tap.dispatchedEvent = { [unowned self] in self.dispatched }
            tap.currentEvent = { [unowned self] in self.current }
        }

        /// Runs `body` inside `event`'s dispatch, as `sendEvent` runs it.
        func send(_ event: NSEvent, _ body: () -> Void = {}) {
            let outer = dispatched
            tap.sendEventBegan(event)
            (dispatched, current) = (event, event)
            tap.deliverObserve(event)
            body()
            dispatched = outer
            tap.sendEventEnded()
        }

        /// Runs `body` inside a menu's action send, as `CmuxApplication.sendAction` brackets a menu item's.
        func menuAction(_ body: () -> Void) {
            tap.menuActionBegan()
            body()
            tap.menuActionEnded()
        }
    }

    @Test func aMenuChoiceWithOptionPressedDuringTrackingReadsOption() throws {
        let rig = Rig()
        let chosen = try Self.mouse(.leftMouseUp, at: 10.4, modifiers: [.option])
        var event: NSEvent?
        // The context menu tracks inside the right-click's dispatch; its loop dequeued the mouse-up itself.
        rig.send(try Self.mouse(.rightMouseDown, at: 10)) {
            rig.current = chosen
            event = rig.tap.actionEvent
        }
        #expect(event === chosen, "the menu's own choosing event is the action's event")
        #expect(event?.modifierFlags.contains(.option) == true, "Option held in the menu is read")
    }

    @Test func aMenuBarChoiceReadsItsTrackingEventOnlyWhileItsActionIsSent() throws {
        let rig = Rig()
        rig.send(try Self.mouse(.leftMouseDown, at: 5))
        // The menu bar tracks outside any dispatch: its mouse-up is the current event, and its action is sent.
        let chosen = try Self.mouse(.leftMouseUp, at: 6, modifiers: [.option])
        rig.current = chosen
        var event: NSEvent?
        rig.menuAction { event = rig.tap.actionEvent }
        #expect(event === chosen)
        #expect(rig.tap.actionEvent == nil, "after the menu's action the menu bar's mouse-up stays current, and a socket run read it")
        rig.menuAction { event = rig.tap.actionEvent }
        #expect(event == nil, "a menu action an accessibility press sends later read the old mouse-up as its own")
    }

    @Test func aControlsTrackingMouseUpIsNoEventAfterItsLoopEnded() throws {
        let rig = Rig()
        // A button's trackMouse dequeued the mouse-up inside the mouse-down's dispatch and never dispatched it.
        let up = try Self.mouse(.leftMouseUp, at: 7.2)
        var inLoop: NSEvent?
        rig.send(try Self.mouse(.leftMouseDown, at: 7)) {
            rig.current = up
            inLoop = rig.tap.actionEvent
        }
        #expect(inLoop === up, "the button's action reads its own mouse-up")
        #expect(rig.tap.actionEvent == nil, "a CLI run after the click read the button's mouse-up")
        var inMenuAction: NSEvent?
        rig.menuAction { inMenuAction = rig.tap.actionEvent }
        #expect(inMenuAction == nil, "the dispatch's end did not retire the mouse-up its loop dequeued")
    }

    @Test func anUnmappedDispatchedEventIsNoActionsEvent() throws {
        let rig = Rig()
        rig.send(try Self.key(at: 20))
        // The tap records no app-defined or mouse-entered event, but `sendEvent` dispatched it: still nil after it.
        let appDefined = try #require(NSEvent.otherEvent(with: .appKitDefined, location: .zero, modifierFlags: [], timestamp: 21,
                                                         windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
        rig.send(appDefined)
        let entered = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 22,
                                                          windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0,
                                                          userData: nil))
        rig.send(entered)
        #expect(rig.tap.lastDispatched?.timestamp == 20, "the tap records neither event")
        #expect(rig.tap.actionEvent == nil)
        var event: NSEvent?
        rig.menuAction { event = rig.tap.actionEvent }
        #expect(event == nil, "a newer unrecorded dispatched event read as a menu's tracking event")
    }

    @Test func theDispatchedEventWinsOverAnOlderTrackingEvent() throws {
        let rig = Rig()
        let stale = try Self.key(at: 30)
        rig.send(stale)
        // The key router's own key (`debug.key`, a held key replayed) is dispatched without `sendEvent`.
        let routed = try Self.key(at: 31)
        rig.dispatched = routed
        #expect(rig.tap.actionEvent === routed)
        rig.current = routed
        #expect(rig.tap.actionEvent === routed)
    }

    @Test func theGateCountsNestedDispatchesAndRaisesItsFloorAtTheOutermostEnd() {
        var gate = InputActionEventGate()
        gate.sendBegan(1)
        gate.sendBegan(2)
        gate.sendEnded(current: nil)
        #expect(gate.sendDepth == 1 && gate.floor == 2)
        gate.sendEnded(current: 3)
        #expect(gate.sendDepth == 0 && gate.floor == 3)
        gate.sendEnded(current: nil)
        #expect(gate.sendDepth == 0, "an unbalanced end goes below zero")
        gate.menuAction(began: true, current: nil)
        gate.menuAction(began: false, current: 4)
        #expect(gate.menuActions == 0 && gate.floor == 4)
    }

    @Test func anUnwiredTapDispatchesNothing() {
        #expect(InputEventTap().dispatchedEvent() == nil)
    }

    private static func key(at timestamp: TimeInterval) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: timestamp,
                                             windowNumber: 0, context: nil, characters: "a",
                                             charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    }

    private static func mouse(_ type: NSEvent.EventType, at timestamp: TimeInterval,
                              modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: timestamp,
                                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}
