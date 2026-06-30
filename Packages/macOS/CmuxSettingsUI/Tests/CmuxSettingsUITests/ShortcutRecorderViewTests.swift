import AppKit
import CmuxSettings
import Testing
@testable import CmuxSettingsUI

@MainActor
@Suite("Shortcut recorder view")
struct ShortcutRecorderViewTests {
    @Test func bareFirstStrokeCanBeAcceptedWhenModifierRequirementIsDisabled() throws {
        let button = RecorderHostButton(frame: .zero)
        defer {
            if button.debugIsRecording {
                button.debugStopRecording()
            }
        }
        button.firstStrokeRequiresModifier = false
        var recordedStroke: ShortcutStroke?
        var rejectedBareKey = false
        button.onStroke = { recordedStroke = $0 }
        button.onBareKeyRejected = { rejectedBareKey = true }
        button.debugStartRecording()

        try #require(button.debugIsRecording)
        button.debugHandleRecordingEvent(try keyDownEvent(key: "j", keyCode: 38))

        #expect(recordedStroke == ShortcutStroke(key: "j", keyCode: 38))
        #expect(!rejectedBareKey)
        #expect(!button.debugIsRecording)
    }

    @Test func bareFirstStrokeIsRejectedByDefault() throws {
        let button = RecorderHostButton(frame: .zero)
        defer {
            if button.debugIsRecording {
                button.debugStopRecording()
            }
        }
        var recordedStroke: ShortcutStroke?
        var rejectedBareKey = false
        button.onStroke = { recordedStroke = $0 }
        button.onBareKeyRejected = { rejectedBareKey = true }
        button.debugStartRecording()

        try #require(button.debugIsRecording)
        button.debugHandleRecordingEvent(try keyDownEvent(key: "j", keyCode: 38))

        #expect(recordedStroke == nil)
        #expect(rejectedBareKey)
        #expect(button.debugIsRecording)
    }

    @Test func recordsArrowKeysAsCanonicalTokens() throws {
        let button = RecorderHostButton(frame: .zero)
        defer {
            if button.debugIsRecording {
                button.debugStopRecording()
            }
        }
        var recordedStroke: ShortcutStroke?
        button.onStroke = { recordedStroke = $0 }
        button.debugStartRecording()

        try #require(button.debugIsRecording)
        // A real Ctrl+Cmd+RightArrow keystroke reports its
        // charactersIgnoringModifiers as the right-arrow function-key scalar
        // (NSRightArrowFunctionKey, a Private Use Area code point), not "→".
        // Storing that raw scalar renders as a missing-glyph "?" and never
        // matches at runtime, so the recorder must canonicalize it to "→".
        button.debugHandleRecordingEvent(
            try arrowKeyDownEvent(functionKey: NSRightArrowFunctionKey, keyCode: 124)
        )

        #expect(
            recordedStroke == ShortcutStroke(key: "→", command: true, control: true, keyCode: 124)
        )
        #expect(!button.debugIsRecording)
    }

    private func arrowKeyDownEvent(functionKey: Int, keyCode: UInt16) throws -> NSEvent {
        let scalar = try #require(UnicodeScalar(functionKey))
        let chars = String(Character(scalar))
        return try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .control],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: chars,
                charactersIgnoringModifiers: chars,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    private func keyDownEvent(key: String, keyCode: UInt16) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: key,
                charactersIgnoringModifiers: key,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }
}
