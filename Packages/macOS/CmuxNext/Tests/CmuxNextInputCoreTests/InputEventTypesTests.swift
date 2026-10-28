import CmuxNextInputCore
import CmuxNextInputCoreTestSupport
import Testing

/// An event-type mask: the classes it subscribes to, and an `observe(types:)`
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
        let tap = FakeInputTap()
        let heard = HeardLog()
        let subscription = tap.observe(types: [.keyDown, .leftMouseDown]) { heard.types.append($0.type) }
        #expect(tap.classes == [.key, .button])
        for type: InputEventType in [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown] {
            tap.deliver(InputEventRecord(type: type, timestamp: 1))
        }
        #expect(heard.types == [.keyDown, .leftMouseDown])
        subscription.cancel()
        #expect(tap.liveSubscriptions == 0)
        tap.deliver(InputEventRecord(type: .keyDown, timestamp: 2))
        #expect(heard.types.count == 2, "a cancelled subscription hears nothing")
    }
}

/// What one test's subscription heard.
@MainActor final class HeardLog {
    var types: [InputEventType] = []
}
