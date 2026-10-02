import AppKit
import CmuxSettings
import Foundation
import Testing
@testable import CmuxSettingsUI

@MainActor
@Suite("Shortcut list search")
struct ShortcutListSearchTests {
    private let commandT = ShortcutStroke(key: "t", command: true)
    private let controlB = ShortcutStroke(key: "b", control: true)
    private let bareC = ShortcutStroke(key: "c")

    @Test func textMatchesEveryWordIgnoringCase() {
        #expect(ShortcutListSearch.text("", matches: ["New Surface"]))
        #expect(ShortcutListSearch.text("new SURF", matches: ["New Surface"]))
        #expect(ShortcutListSearch.text("surface terminal", matches: ["New Surface", "Only while a terminal pane is focused"]))
        #expect(!ShortcutListSearch.text("new browser", matches: ["New Surface"]))
    }

    @Test func oneStrokeFindsExactBindingsAndChordsStartingWithIt() {
        let keys = StoredShortcut(first: controlB)
        #expect(ShortcutListSearch.keys(keys, match: StoredShortcut(first: controlB), numbered: false))
        #expect(ShortcutListSearch.keys(keys, match: StoredShortcut(first: controlB, second: bareC), numbered: false))
        #expect(!ShortcutListSearch.keys(keys, match: StoredShortcut(first: commandT), numbered: false))
        #expect(!ShortcutListSearch.keys(keys, match: .unbound, numbered: false))
        #expect(!ShortcutListSearch.keys(keys, match: nil, numbered: false))
    }

    @Test func twoStrokesFindOnlyTheMatchingChord() {
        let keys = StoredShortcut(first: controlB, second: bareC)
        #expect(ShortcutListSearch.keys(keys, match: StoredShortcut(first: controlB, second: bareC), numbered: false))
        #expect(!ShortcutListSearch.keys(keys, match: StoredShortcut(first: controlB), numbered: false))
        #expect(!ShortcutListSearch.keys(
            keys,
            match: StoredShortcut(first: controlB, second: ShortcutStroke(key: "p")),
            numbered: false
        ))
    }

    @Test func anyDigitFindsANumberedFamily() {
        let family = StoredShortcut(first: ShortcutStroke(key: "1", control: true))
        let controlFive = StoredShortcut(first: ShortcutStroke(key: "5", control: true))
        #expect(ShortcutListSearch.keys(controlFive, match: family, numbered: true))
        #expect(!ShortcutListSearch.keys(controlFive, match: family, numbered: false))
    }

    @Test func keyMatchingIgnoresRecordedKeyCode() {
        let recorded = StoredShortcut(first: ShortcutStroke(key: "t", command: true, keyCode: 17))
        #expect(ShortcutListSearch.keys(recorded, match: StoredShortcut(first: commandT), numbered: false))
    }

    @Test func chordStartsOnlyForChordBindings() {
        let bindings: [StoredShortcut?] = [StoredShortcut(first: commandT), nil, StoredShortcut(first: controlB, second: bareC)]
        #expect(ShortcutListSearch.chordStarts(with: controlB, in: bindings))
        #expect(!ShortcutListSearch.chordStarts(with: commandT, in: bindings))
    }

    @Test func modelFiltersVisibleActionsByPressedKeys() throws {
        let model = makeModel()
        let all = model.actions(matching: ShortcutListSearchQuery())
        #expect(all == ShortcutAction.settingsVisibleActions)

        let byKeys = model.actions(matching: ShortcutListSearchQuery(keys: StoredShortcut(first: commandT)))
        #expect(byKeys.contains(.newSurface))
        #expect(byKeys.allSatisfy { action in
            ShortcutListSearch.keys(
                StoredShortcut(first: commandT),
                match: model.effective(for: action),
                numbered: action.usesNumberedDigitMatching
            )
        })
    }

    @Test func modelCombinesTextAndKeys() {
        let model = makeModel()
        let keys = StoredShortcut(first: commandT)
        #expect(model.actions(matching: ShortcutListSearchQuery(text: "surface", keys: keys)).contains(.newSurface))
        #expect(model.actions(matching: ShortcutListSearchQuery(text: "zzz no such action", keys: keys)).isEmpty)
    }

    @Test func detectorWaitsForSecondStrokeOnlyWhenAChordStartsWithTheFirst() throws {
        let button = RecorderHostButton(frame: .zero)
        defer { button.cancelRecordingIfActive() }
        var firstStroke: ShortcutStroke?
        var stroke: ShortcutStroke?
        var chord: StoredShortcut?
        button.firstStrokeRequiresModifier = false
        button.awaitsSecondStroke = { $0.control && $0.key == "b" }
        button.onFirstStroke = { firstStroke = $0 }
        button.onStroke = { stroke = $0 }
        button.onChord = { chord = $0 }

        button.startRecording()
        button.handleRecordingEvent(try keyDownEvent(key: "t", keyCode: 17, modifierFlags: [.command]))
        #expect(stroke?.key == "t")
        #expect(firstStroke == nil)
        #expect(!button.isRecording)

        button.startRecording()
        button.handleRecordingEvent(try keyDownEvent(key: "b", keyCode: 11, modifierFlags: [.control]))
        #expect(firstStroke?.key == "b")
        #expect(button.isRecording)
        button.handleRecordingEvent(try keyDownEvent(key: "c", keyCode: 8))
        #expect(chord?.first.key == "b")
        #expect(chord?.second?.key == "c")
        #expect(!button.isRecording)
    }

    @Test func recorderUsesCustomRecordingPrompt() {
        let button = RecorderHostButton(frame: .zero)
        defer { button.cancelRecordingIfActive() }
        button.placeholder = "Record Keys"
        button.recordingPrompt = "Press keys…"
        button.refreshTitle()
        #expect(button.title == "Record Keys")
        button.startRecording()
        #expect(button.title == "Press keys…")
    }

    private func makeModel() -> ShortcutListModel {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcut-list-search-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("cmux.json")
        return ShortcutListModel(
            jsonStore: JSONConfigStore(fileURL: fileURL),
            catalog: SettingCatalog(),
            errorLog: SettingsErrorLog()
        )
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
