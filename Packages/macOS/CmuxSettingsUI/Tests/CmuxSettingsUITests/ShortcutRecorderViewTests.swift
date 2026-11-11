import AppKit
import Carbon
import CmuxSettings
import Testing
@testable import CmuxSettingsUI

@MainActor
// Serialized: recorders share process-wide state (the active recorder and its
// Carbon registrations), so interleaved tests would steal each other's recorder.
@Suite("Shortcut recorder view", .serialized)
struct ShortcutRecorderViewTests {
    @Test func CarbonEscapeAssistRegistersOnlyCommandEscape() {
        let modifierSets = RecorderHostButton.carbonEscapeModifierSets()

        #expect(modifierSets.contains(UInt32(cmdKey)))
        #expect(!modifierSets.contains(UInt32(cmdKey | optionKey)))
    }

    @Test func CarbonModifierFlagsMapToAppKitModifiers() {
        let modifiers = UInt32(cmdKey | shiftKey | controlKey)

        #expect(
            RecorderHostButton.modifierFlags(fromCarbonModifiers: modifiers)
                == [.command, .shift, .control]
        )
    }

    @Test func commandEscapeRecordsThroughTheStandardRecorderPath() throws {
        let button = RecorderHostButton(frame: .zero)
        defer { button.cancelRecordingIfActive() }
        var recordedStroke: ShortcutStroke?
        button.onStroke = { recordedStroke = $0 }
        button.startRecording()

        button.handleRecordingEvent(try keyDownEvent(
            key: "\u{1b}",
            keyCode: UInt16(kVK_Escape),
            modifierFlags: [.command]
        ))

        #expect(recordedStroke == ShortcutStroke(key: "escape", command: true, keyCode: UInt16(kVK_Escape)))
        #expect(!button.isRecording)
    }

    @Test func carbonCommandEscapeFireRecordsForASystemWideRecorderWithKeyFocus() throws {
        let button = RecorderHostButton(frame: .zero)
        defer { button.cancelRecordingIfActive() }
        button.recordsSystemWideHotkey = true
        var recordedStroke: ShortcutStroke?
        button.onStroke = { recordedStroke = $0 }
        button.startRecording()
        try #require(button.isRecording)

        let handled = RecorderHostButton.deliverCarbonEscapeHotKey(id: 1, to: button, hasKeyFocus: true)

        #expect(handled)
        #expect(recordedStroke == ShortcutStroke(key: "escape", command: true, keyCode: UInt16(kVK_Escape)))
        #expect(!button.isRecording)
    }

    @Test func carbonCommandEscapeFireIsIgnoredForAForegroundRecorder() throws {
        // macOS withholds the Cmd+Escape keyDown, so a foreground binding could
        // never fire it; the recorder must not let one be saved.
        let button = RecorderHostButton(frame: .zero)
        defer { button.cancelRecordingIfActive() }
        var recordedStroke: ShortcutStroke?
        button.onStroke = { recordedStroke = $0 }
        button.startRecording()
        try #require(button.isRecording)

        let handled = RecorderHostButton.deliverCarbonEscapeHotKey(id: 1, to: button, hasKeyFocus: true)

        #expect(!handled)
        #expect(recordedStroke == nil)
        #expect(button.isRecording)
    }

    @Test func carbonCommandEscapeFireIsIgnoredWithoutKeyFocusOrForUnknownIDs() throws {
        let button = RecorderHostButton(frame: .zero)
        defer { button.cancelRecordingIfActive() }
        button.recordsSystemWideHotkey = true
        var recordedStroke: ShortcutStroke?
        button.onStroke = { recordedStroke = $0 }
        button.startRecording()
        try #require(button.isRecording)

        #expect(!RecorderHostButton.deliverCarbonEscapeHotKey(id: 1, to: button, hasKeyFocus: false))
        #expect(!RecorderHostButton.deliverCarbonEscapeHotKey(id: 0, to: button, hasKeyFocus: true))
        #expect(!RecorderHostButton.deliverCarbonEscapeHotKey(id: 99, to: button, hasKeyFocus: true))
        #expect(!RecorderHostButton.deliverCarbonEscapeHotKey(id: 1, to: nil, hasKeyFocus: true))
        #expect(recordedStroke == nil)
        #expect(button.isRecording)
    }

    @Test func systemWideRecorderRegistersTheCarbonAssistWhileRecording() throws {
        let button = RecorderHostButton(frame: .zero)
        defer { button.cancelRecordingIfActive() }
        button.recordsSystemWideHotkey = true

        button.startRecording()
        try #require(button.isRecording)
        #expect(RecorderHostButton.isCarbonEscapeAssistRegistered)
        #expect(!button.carbonEscapeAssistUnavailable)

        button.stopRecording()
        #expect(!RecorderHostButton.isCarbonEscapeAssistRegistered)
    }

    @Test func foregroundRecorderNeverRegistersTheCarbonAssist() throws {
        let button = RecorderHostButton(frame: .zero)
        defer { button.cancelRecordingIfActive() }

        button.startRecording()
        try #require(button.isRecording)
        #expect(!RecorderHostButton.isCarbonEscapeAssistRegistered)
    }

    @Test func carbonAssistReportsFailureWhenCommandEscapeIsStillHeld() async throws {
        // Stands in for an app hotkey that did not stand down: Carbon refuses a
        // second registration of a combo this process already holds.
        var heldRef: EventHotKeyRef?
        let held = RegisterEventHotKey(
            UInt32(kVK_Escape),
            UInt32(cmdKey),
            EventHotKeyID(signature: 0x54455354, id: 1), // "TEST"
            GetApplicationEventTarget(),
            0,
            &heldRef
        )
        try #require(held == noErr)
        defer { if let heldRef { UnregisterEventHotKey(heldRef) } }

        let button = RecorderHostButton(frame: .zero)
        defer { button.cancelRecordingIfActive() }
        button.recordsSystemWideHotkey = true
        button.startRecording()
        try await Task.sleep(for: .milliseconds(50)) // let the one retry run

        #expect(button.isRecording)
        #expect(button.carbonEscapeAssistUnavailable)
        #expect(!RecorderHostButton.isCarbonEscapeAssistRegistered)
    }

    @Test func carbonCommandEscapeFireIsIgnoredWhenNotRecording() {
        let button = RecorderHostButton(frame: .zero)
        button.recordsSystemWideHotkey = true
        var recordedStroke: ShortcutStroke?
        button.onStroke = { recordedStroke = $0 }

        #expect(!RecorderHostButton.deliverCarbonEscapeHotKey(id: 1, to: button, hasKeyFocus: true))
        #expect(recordedStroke == nil)
    }

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
