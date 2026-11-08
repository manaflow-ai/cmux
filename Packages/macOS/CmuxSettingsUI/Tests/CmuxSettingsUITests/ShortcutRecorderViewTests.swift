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

    @Test func commandShiftLessThanIsRejectedAsReloadConfigurationCollision() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcut-recorder-collision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let button = RecorderHostButton(frame: .zero)
        defer {
            if button.isRecording {
                button.stopRecording()
            }
        }
        var recordedStroke: ShortcutStroke?
        button.onStroke = { recordedStroke = $0 }
        button.startRecording()
        button.handleRecordingEvent(try keyDownEvent(
            key: "<",
            keyCode: 43,
            modifierFlags: [.command, .shift]
        ))

        let stroke = try #require(recordedStroke)
        let store = JSONConfigStore(fileURL: tempDirectory.appendingPathComponent("cmux.json"))
        let catalog = SettingCatalog()
        let model = ShortcutListModel(
            jsonStore: store,
            catalog: catalog,
            errorLog: SettingsErrorLog()
        )

        await model.assign(stroke: stroke, to: .focusHistoryBack)

        let bindings = await store.value(for: catalog.shortcuts.bindings)
        #expect(bindings[ShortcutAction.focusHistoryBack.rawValue] == nil)
        #expect(
            model.conflictRejections[ShortcutAction.focusHistoryBack.rawValue]
                == .reloadConfiguration
        )
    }

    @Test func unmappedPrintableSymbolRemainsRecordable() throws {
        let button = RecorderHostButton(frame: .zero)
        defer {
            if button.isRecording {
                button.stopRecording()
            }
        }
        var recordedStroke: ShortcutStroke?
        button.onStroke = { recordedStroke = $0 }
        button.startRecording()

        button.handleRecordingEvent(try keyDownEvent(
            key: "§",
            keyCode: 10,
            modifierFlags: [.command]
        ))

        #expect(recordedStroke?.key == "§")
        #expect(recordedStroke?.keyCode == 10)
    }

    private func keyDownEvent(
        key: String,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifierFlags,
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
