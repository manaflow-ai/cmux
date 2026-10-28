import AppKit
import CmuxNextInputCore
import CmuxNextInputCoreTestSupport
import CmuxNextWakeups
import Testing

/// The production pending-input seam hears AppKit's dispatched events through the app's input tap
/// (``InputObserving``), with the same event types and scroll phases the local
/// monitor it replaced reported.
@MainActor @Suite struct WindowServerInputEventsTests {
    @Test func observesTheTapOnceForKeysButtonsMovesDragsAndScrolls() {
        let tap = FakeInputTap()
        let events = WindowServerInputEvents(input: tap)
        let seen = DispatchedLog()
        events.observeDispatch { seen.items.append($0) }
        events.observeDispatch { seen.items.append($0) }
        #expect(tap.liveSubscriptions == 1, "a second call keeps the one subscription")
        #expect(tap.classes == [.key, .flags, .button, .pointerMove, .drag, .scroll], "no trackpad gestures, as the old mask")
        tap.deliver(InputEventRecord(type: .keyDown, timestamp: 10))
        tap.deliver(InputEventRecord(type: .magnify, timestamp: 11))
        tap.deliver(InputEventRecord(type: .leftMouseDragged, timestamp: 12))
        #expect(seen.items == [.init(timestamp: 10, kind: .keyOrClick), .init(timestamp: 12, kind: .leftDrag)])
    }

    /// The pending-input check watches the tap from its init: no app or check has to come first.
    @Test func thePendingInputCheckHearsTheTapFromItsInit() {
        let tap = FakeInputTap()
        let pending = SessionInputPending(events: WindowServerInputEvents(input: tap))
        withExtendedLifetime(pending) { #expect(tap.liveSubscriptions == 1) }
    }

    @Test func eachTypeKeepsTheKindTheMonitorReported() {
        let kinds: [(InputEventType, SessionInputPending.Dispatched.Kind)] = [
            (.keyDown, .keyOrClick), (.rightMouseDown, .keyOrClick), (.otherMouseDown, .keyOrClick),
            (.leftMouseDown, .leftMouseDown), (.leftMouseUp, .leftMouseUp), (.leftMouseDragged, .leftDrag),
            (.keyUp, .other), (.flagsChanged, .other), (.mouseMoved, .other), (.rightMouseDragged, .other), (.otherMouseUp, .other),
        ]
        for (type, kind) in kinds {
            #expect(SessionInputPending.Dispatched.Kind(InputEventRecord(type: type, timestamp: 1)) == kind, "\(type)")
        }
    }

    @Test func scrollPhasesReachTheLatchingRules() {
        let latching = SessionInputPending.ScrollLatching(wheelLatching: 0.5, momentumWait: 0.1)
        func openUntil(_ phase: InputScrollPhase) -> TimeInterval? {
            guard case let .scroll(gesture, momentum) = SessionInputPending.Dispatched.Kind(
                InputEventRecord(type: .scrollWheel, timestamp: 10, scrollPhase: phase)) else { return nil }
            return latching.sequenceOpen(after: 10, phase: gesture, momentum: momentum)
        }
        #expect(openUntil(.none) == 10.5, "a wheel notch latches")
        #expect(openUntil(.began) == .infinity)
        #expect(openUntil(.changed) == .infinity)
        #expect(openUntil(.ended) == 10.1, "a phase end waits for momentum")
        #expect(openUntil(.momentum) == .infinity, "a coast continues the gesture")
        #expect(openUntil(.momentumEnded) == 10, "the coast's end closes the sequence")
        #expect(openUntil(.cancelled) == 10)
        #expect(openUntil(.mayBegin) == 10)
    }
}

/// The dispatched events one test heard.
@MainActor final class DispatchedLog {
    var items: [SessionInputPending.Dispatched] = []
}
