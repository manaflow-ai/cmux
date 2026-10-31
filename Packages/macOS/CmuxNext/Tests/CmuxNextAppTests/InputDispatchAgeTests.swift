import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// A key the app routes itself (`debug.key`, a replayed held key: `KeyRouter.dispatchingSynthetic`) is the
/// event the action signposts and the key-down checks read, so a Cmd-T from automation records its input age
/// (`action.input_to_commit`) instead of `input_age_ms = -1`, and a stale `NSApp.currentEvent` (the last key
/// AppKit dequeued, kept after its dispatch) is never taken for it.
@MainActor @Suite(.serialized)
struct InputDispatchAgeTests {
    private static func key(_ characters: String, keyCode: UInt16, at timestamp: TimeInterval) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: timestamp,
                                      windowNumber: 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    @Test func aKeyTheRouterDispatchesCarriesItsOwnInputAge() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let now = ProcessInfo.processInfo.systemUptime
        let cmdT = try Self.key("t", keyCode: 17, at: now - 0.005)
        // A stale key in `currentEvent`, as a finished dispatch leaves it (KeyDownDispatchTests' way in).
        let stale = try Self.key("w", keyCode: 13, at: now - 30)
        try #require(class_getInstanceVariable(NSApplication.self, "_currentEvent") != nil, "NSApplication has no _currentEvent ivar")
        NSApp.setValue(stale, forKey: "currentEvent")
        defer { NSApp.setValue(nil, forKey: "currentEvent") }

        let (event, keyDown) = services.keyRouter.dispatchingSynthetic(cmdT) {
            (services.registry.dispatchingInputEvent(), services.registry.isDispatchingKeyDown())
        }
        #expect(event === cmdT, "the event being dispatched is not the key the router dispatched")
        #expect(keyDown, "a key the router dispatched is not a key-down dispatch (Cmd-C, menu gate)")
        let age = ActionRegistry.inputAgeMilliseconds(origin: .user, event: event, now: ProcessInfo.processInfo.systemUptime)
        #expect(age >= 5 && age < 5_000, "input age \(age) ms (want the key's own, not -1 or the stale key's 30 s)")
        #expect(services.registry.dispatchingInputEvent() == nil, "the dispatch ended but an event is still reported")
        #expect(!services.registry.isDispatchingKeyDown())
    }
}
