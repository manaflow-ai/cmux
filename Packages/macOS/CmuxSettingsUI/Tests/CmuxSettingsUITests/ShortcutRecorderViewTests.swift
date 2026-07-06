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
            if button.isRecording {
                button.stopRecording()
            }
        }
        button.firstStrokeRequiresModifier = false
        var recordedStroke: ShortcutStroke?
        var rejectedBareKey = false
        button.onStroke = { recordedStroke = $0 }
        button.onBareKeyRejected = { rejectedBareKey = true }
        button.startRecording()

        try #require(button.isRecording)
        button.handleRecordingEvent(try keyDownEvent(key: "j", keyCode: 38))

        #expect(recordedStroke == ShortcutStroke(key: "j", keyCode: 38))
        #expect(!rejectedBareKey)
        #expect(!button.isRecording)
    }

    @Test func bareFirstStrokeIsRejectedByDefault() throws {
        let button = RecorderHostButton(frame: .zero)
        defer {
            if button.isRecording {
                button.stopRecording()
            }
        }
        var recordedStroke: ShortcutStroke?
        var rejectedBareKey = false
        button.onStroke = { recordedStroke = $0 }
        button.onBareKeyRejected = { rejectedBareKey = true }
        button.startRecording()

        try #require(button.isRecording)
        button.handleRecordingEvent(try keyDownEvent(key: "j", keyCode: 38))

        #expect(recordedStroke == nil)
        #expect(rejectedBareKey)
        #expect(button.isRecording)
    }

    @Test func cancelRecordingIfActiveStopsRecording() throws {
        // Reused-for-another-action cells must not stay armed; cancelRecordingIfActive must
        // disarm an active recorder idempotently so Task 5 cell reuse is safe.
        let button = RecorderHostButton(frame: .zero)
        defer {
            if button.isRecording {
                button.stopRecording()
            }
        }
        button.startRecording()
        try #require(button.isRecording)
        button.cancelRecordingIfActive()
        #expect(!button.isRecording)
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
