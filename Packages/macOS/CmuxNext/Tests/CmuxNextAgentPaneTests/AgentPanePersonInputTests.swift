import AppKit
@testable import CmuxNextAgentPane
import CmuxNextInput
import Testing

/// A native choice grants the agent pane a gesture only from the event it answers (p04-input-067): a script or
/// socket run right after the person's key is not the person, though AppKit still keeps that key as its current event.
@MainActor @Suite(.serialized)
struct AgentPanePersonInputTests {
    /// The event a fake dispatch holds: a class, so the `@MainActor` source shares it without capturing a local `var`.
    final class Dispatch {
        var event: NSEvent?
    }

    @Test func aRunAfterThePersonsKeyIsNotThePerson() throws {
        _ = NSApplication.shared
        let tap = InputEventTap()
        let dispatch = Dispatch()
        tap.dispatchedEvent = { dispatch.event }
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                                context: nil, characters: "v", charactersIgnoringModifiers: "v",
                                                isARepeat: false, keyCode: 9))
        try #require(class_getInstanceVariable(NSApplication.self, "_currentEvent") != nil, "NSApplication has no _currentEvent ivar")
        NSApp.setValue(key, forKey: "currentEvent")
        defer { NSApp.setValue(nil, forKey: "currentEvent") }

        tap.deliverObserve(key)
        dispatch.event = key
        #expect(AgentPanePersonInput.isPerson(answering: tap) == AgentPanePersonInput.isPerson(key),
                "the key being dispatched is the event its paste answers")
        dispatch.event = nil
        #expect(!AgentPanePersonInput.isPerson(answering: tap), "a run after the dispatch took the person's key as its own")
    }
}
