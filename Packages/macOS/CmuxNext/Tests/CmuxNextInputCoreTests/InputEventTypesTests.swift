import CmuxNextInputCore
import Testing

/// An event-type mask (p04-input-012): the classes it subscribes to, and an `observe(types:)`
/// subscription that hears only its own types, as the AppKit monitor mask it replaces did.
@MainActor struct InputEventTypesTests {
    @Test func holdsItsTypesAndNamesTheirClasses() {
        let types: InputEventTypes = [.keyDown, .leftMouseDown, .scrollWheel, .leftMouseDragged]
        #expect(types.contains(.keyDown))
        #expect(types.contains(.scrollWheel))
        #expect(!types.contains(.keyUp))
        #expect(!types.contains(.rightMouseDragged))
        #expect(types.classes == [.key, .button, .scroll, .drag])
        #expect(([] as InputEventTypes).classes.isEmpty)
        #expect(([.pressure] as InputEventTypes).classes == .gesture)
    }

    @Test func observeTypesSkipsTheOtherTypesOfItsClasses() {
        let tap = TypesFakeTap()
        let heard = HeardLog()
        let subscription = tap.observe(types: [.keyDown, .leftMouseDown]) { heard.types.append($0.type) }
        #expect(tap.classes == [.key, .button])
        for type: InputEventType in [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown] {
            tap.deliver(InputEventRecord(type: type, timestamp: 1))
        }
        #expect(heard.types == [.keyDown, .leftMouseDown])
        subscription.cancel()
        tap.deliver(InputEventRecord(type: .keyDown, timestamp: 2))
        #expect(heard.types.count == 2, "a cancelled subscription hears nothing")
    }
}

/// What one test's subscription heard.
@MainActor final class HeardLog {
    var types: [InputEventType] = []
}

/// An ``InputObserving`` whose events a test delivers by hand.
@MainActor final class TypesFakeTap: InputObserving {
    private var entries: [(classes: InputEventClasses, flag: InputSubscriptionFlag, handler: @MainActor (InputEventRecord) -> Void)] = []
    var lastDispatched: InputEventRecord?
    var lastPointer: InputEventRecord?

    func observe(_ classes: InputEventClasses, windowNumber: Int?,
                 _ handler: @escaping @MainActor (InputEventRecord) -> Void) -> InputSubscription {
        let flag = InputSubscriptionFlag()
        entries.append((classes, flag, handler))
        return InputSubscription(flag: flag)
    }

    /// The classes all subscriptions asked for.
    var classes: InputEventClasses { entries.reduce(into: []) { $0.formUnion($1.classes) } }

    func deliver(_ record: InputEventRecord) {
        for entry in entries where !entry.flag.isCancelled && entry.classes.contains(record.eventClass) { entry.handler(record) }
    }
}
