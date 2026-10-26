import AppKit
import CmuxNextInputCore
import CmuxNextWakeups
import Testing

/// The production pending-input seam hears AppKit's dispatched events through the app's input tap
/// (``InputObserving``, p04-input-012), with the same event types and scroll phases the local
/// monitor it replaced reported.
@MainActor @Suite struct WindowServerInputEventsTests {
    @Test func observesTheTapOnceForKeysButtonsMovesDragsAndScrolls() {
        let tap = FakeInputTap()
        let events = WindowServerInputEvents(input: tap)
        let seen = DispatchedLog()
        #expect(events.observeDispatch { seen.items.append($0) })
        #expect(events.observeDispatch { seen.items.append($0) }, "a second call keeps the one subscription")
        #expect(tap.liveSubscriptions == 1)
        #expect(tap.classes == [.key, .flags, .button, .pointerMove, .drag, .scroll], "no trackpad gestures, as the old mask")
        tap.deliver(InputEventRecord(type: .keyDown, timestamp: 10))
        tap.deliver(InputEventRecord(type: .magnify, timestamp: 11))
        tap.deliver(InputEventRecord(type: .leftMouseDragged, timestamp: 12))
        #expect(seen.items == [.init(timestamp: 10, kind: .keyOrClick), .init(timestamp: 12, kind: .leftDrag)])
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

/// An ``InputObserving`` whose events a test delivers by hand.
@MainActor final class FakeInputTap: InputObserving {
    private var entries: [(classes: InputEventClasses, flag: InputSubscriptionFlag, handler: @MainActor (InputEventRecord) -> Void)] = []
    var lastDispatched: InputEventRecord?
    var lastPointer: InputEventRecord?

    func observe(_ classes: InputEventClasses, windowNumber: Int?,
                 _ handler: @escaping @MainActor (InputEventRecord) -> Void) -> InputSubscription {
        let flag = InputSubscriptionFlag()
        entries.append((classes, flag, handler))
        return InputSubscription(flag: flag)
    }

    /// The subscriptions not cancelled or released.
    var liveSubscriptions: Int { entries.count(where: { !$0.flag.isCancelled }) }

    /// The classes of the live subscriptions.
    var classes: InputEventClasses {
        entries.filter { !$0.flag.isCancelled }.reduce(into: []) { $0.formUnion($1.classes) }
    }

    /// AppKit dispatched `record`: every live subscription of its class hears it.
    func deliver(_ record: InputEventRecord) {
        lastDispatched = record
        for entry in entries where !entry.flag.isCancelled && entry.classes.contains(record.eventClass) { entry.handler(record) }
    }
}
