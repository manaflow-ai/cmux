import AppKit
import CmuxNextFocusUI
import Testing

/// ``InputDispatchContext``: nested dispatches (a synthetic event sent from inside another dispatch, as
/// `DebugNativeInput.sendThroughApp` does) report the innermost event, the outer one again after it, and none
/// after the last one ends. A scroll is under way from each scroll event until its gap passed (the frames that show
/// a scroll come between its events), so background work that reads `inputUnderWay` stays out of them.
@MainActor @Suite
struct InputDispatchContextTests {
    /// Seconds since boot that the test moves.
    @MainActor private final class Uptime {
        var now: TimeInterval = 100
    }

    /// One scroll event of a gesture (`phase`) or of its momentum, as AppKit gives it to `sendEvent`.
    private static func scroll(phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase = .none) throws -> NSEvent {
        _ = NSApplication.shared
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -12, wheel2: 0, wheel3: 0))
        if let phase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        return try #require(NSEvent(cgEvent: cg))
    }

    private static func event(_ type: NSEvent.EventType, at timestamp: TimeInterval) throws -> NSEvent {
        _ = NSApplication.shared
        if type == .keyDown {
            return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: timestamp,
                                                 windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                                                 isARepeat: false, keyCode: 0))
        }
        return try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: timestamp, windowNumber: 0,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test func nestedDispatchesReportTheInnermostEvent() throws {
        let context = InputDispatchContext()
        let click = try Self.event(.leftMouseDown, at: 1)
        let key = try Self.event(.keyDown, at: 2)
        #expect(context.event == nil)
        context.dispatching(click) {
            #expect(context.event === click)
            #expect(!context.isKeyDown)
            context.dispatching(key) {
                #expect(context.event === key)
                #expect(context.isKeyDown)
            }
            #expect(context.event === click)
        }
        #expect(context.event == nil)
        #expect(!context.isKeyDown)
    }

    /// Between the events of a scroll no event is in dispatch, and those are the frames that show it. Input is
    /// under way there all the same, until the events stop for the gap. A key or a click holds only its dispatch.
    @Test func aScrollIsUnderWayBetweenItsEventsAndUntilTheyStop() throws {
        let clock = Uptime()
        let context = InputDispatchContext(uptime: { clock.now })
        let gap = InputDispatchContext.scrollGap
        #expect(!context.scrollUnderWay && !context.inputUnderWay)

        let key = try Self.event(.keyDown, at: 1)
        context.dispatching(key) { #expect(context.inputUnderWay && !context.scrollUnderWay) }
        #expect(!context.inputUnderWay, "a key held input under way after its dispatch")

        // The gesture: between its events nothing is in dispatch.
        context.dispatching(try Self.scroll(phase: .began)) {}
        #expect(context.event == nil)
        #expect(context.scrollUnderWay && context.inputUnderWay, "no scroll is under way after a gesture's first event")
        clock.now += 0.016
        context.dispatching(try Self.scroll(phase: .changed)) {}
        clock.now += 0.016
        context.dispatching(try Self.scroll(phase: .ended)) {}
        #expect(context.scrollUnderWay, "the gesture's end ended the scroll before its momentum's first event")
        // Its momentum: an event each frame, each inside the gap of the one before.
        clock.now += gap / 2
        context.dispatching(try Self.scroll(momentum: .begin)) {}
        clock.now += gap / 2
        context.dispatching(try Self.scroll(momentum: .continuous)) {}
        clock.now += gap / 2
        #expect(context.scrollUnderWay && context.inputUnderWay, "the scroll ended while its momentum's events came")
        context.dispatching(try Self.scroll(momentum: .end)) {}

        // The events stopped: under way until the gap passed, then not.
        clock.now += gap / 2
        #expect(context.scrollUnderWay)
        clock.now += gap
        #expect(!context.scrollUnderWay && !context.inputUnderWay, "a scroll stayed under way after its events stopped")

        // A click is no scroll.
        context.dispatching(try Self.event(.leftMouseDown, at: 2)) {}
        #expect(!context.scrollUnderWay && !context.inputUnderWay)
    }
}
