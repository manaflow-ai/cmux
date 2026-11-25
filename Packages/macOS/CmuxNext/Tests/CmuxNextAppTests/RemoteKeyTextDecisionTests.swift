import AppKit
@testable import CmuxNextRemoteView
import Testing

/// A key event whose characters are not what its key code types on the
/// viewer's layout goes to the host as text (CMUX-572: a tool that posts each
/// character with key code 0 typed "a" for every one).
@MainActor
struct RemoteKeyTextDecisionTests {
    final class Recorder: RemoteViewInputSink {
        var events: [RemoteInputEvent] = []
        func send(_ event: RemoteInputEvent) { events.append(event) }
    }

    /// A controller in control mode on a US layout, where key code 0 types "a".
    func controller(_ recorder: Recorder) -> RemoteInputController {
        let controller = RemoteInputController()
        controller.sink = recorder
        controller.inputSourceIsASCIICapable = { true }
        controller.layoutCharacters = { keyCode, modifiers in
            keyCode == 0 ? (modifiers.contains(.shift) ? "A" : "a") : nil
        }
        controller.isActive = true
        return controller
    }

    func keyEvent(_ type: NSEvent.EventType, keyCode: UInt16, characters: String,
                  modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode))
    }

    @Test func keyCodeZeroWithAnotherCharacterSendsText() throws {
        let recorder = Recorder()
        let controller = controller(recorder)
        #expect(controller.keyDown(try keyEvent(.keyDown, keyCode: 0, characters: "x")) == .handled)
        controller.keyUp(try keyEvent(.keyUp, keyCode: 0, characters: "x"))
        #expect(recorder.events == [.text("x")])
    }

    @Test func keyCodeZeroWithItsOwnCharacterSendsTheKey() throws {
        let recorder = Recorder()
        let controller = controller(recorder)
        #expect(controller.keyDown(try keyEvent(.keyDown, keyCode: 0, characters: "a")) == .handled)
        controller.keyUp(try keyEvent(.keyUp, keyCode: 0, characters: "a"))
        #expect(recorder.events == [.key(usage: 0x0007_0004, down: true), .key(usage: 0x0007_0004, down: false)])
    }

    /// A key code with no HID key (255) and text attached sent nothing.
    @Test func unmappedKeyCodeWithTextSendsText() throws {
        let recorder = Recorder()
        let controller = controller(recorder)
        #expect(controller.keyDown(try keyEvent(.keyDown, keyCode: 255, characters: "é")) == .handled)
        controller.keyUp(try keyEvent(.keyUp, keyCode: 255, characters: "é"))
        #expect(recorder.events == [.text("é")])
    }

    @Test func policyKeepsChordsDeadKeysAndControlCharactersPhysical() {
        let policy = RemoteKeyboardPolicy()
        #expect(policy.sendsAsText(characters: "é", layoutCharacters: "a", modifiers: []))
        #expect(policy.sendsAsText(characters: "😀", layoutCharacters: "a", modifiers: []))
        #expect(!policy.sendsAsText(characters: "A", layoutCharacters: "A", modifiers: [.shift]))
        #expect(!policy.sendsAsText(characters: "x", layoutCharacters: "a", modifiers: [.command]))
        #expect(!policy.sendsAsText(characters: "", layoutCharacters: "´", modifiers: [.option]))
        #expect(!policy.sendsAsText(characters: "\r", layoutCharacters: "a", modifiers: []))
        #expect(!policy.sendsAsText(characters: "\u{F702}", layoutCharacters: nil, modifiers: []))
        #expect(!policy.sendsAsText(characters: "x", layoutCharacters: nil, modifiers: []))
    }
}
