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
        #expect(ShortcutListSearch.textScore("", title: "New Surface", details: []) != nil)
        #expect(ShortcutListSearch.textScore("new SURF", title: "New Surface", details: []) != nil)
        #expect(ShortcutListSearch.textScore(
            "surface terminal",
            title: "New Surface",
            details: ["Only while a terminal pane is focused"]
        ) != nil)
        #expect(ShortcutListSearch.textScore("new browser", title: "New Surface", details: []) == nil)
    }

    @Test func titleMatchOutranksCaptionMatch() throws {
        let titled = try #require(ShortcutListSearch.textScore("browser", title: "Open Browser", details: []))
        let captioned = try #require(ShortcutListSearch.textScore(
            "browser",
            title: "Next Diff Hunk",
            details: ["Only while a browser pane is focused"]
        ))
        #expect(titled < captioned)
    }

    @Test func titleToleratesTyposButCaptionsDoNot() {
        #expect(ShortcutListSearch.textScore("surfce", title: "New Surface", details: []) != nil)
        #expect(ShortcutListSearch.textScore(
            "brwser",
            title: "Next Diff Hunk",
            details: ["Only while a browser pane is focused"]
        ) == nil)
    }

    @Test func modelRanksTitleMatchesFirst() throws {
        let model = makeModel()
        let results = model.actions(matching: ShortcutListSearchQuery(text: "browser"))
        let titleHits = results.map { $0.displayName.localizedCaseInsensitiveContains("browser") }
        try #require(titleHits.contains(true))
        // Once a caption-only match appears, no title match may follow it.
        let firstCaptionOnly = titleHits.firstIndex(of: false) ?? titleHits.endIndex
        #expect(!titleHits[firstCaptionOnly...].contains(true))
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

    @Test func refreshKeepsShownRowsAndAddsNewMatches() {
        let model = makeModel()
        let query = ShortcutListSearchQuery(keys: StoredShortcut(first: commandT))
        let shown = model.actions(matching: query)
        #expect(!shown.contains(.openSettings))

        // Unbind a shown row and give another action the searched keys.
        model.bindings[ShortcutAction.newSurface.rawValue] = .unbound
        model.bindings[ShortcutAction.openSettings.rawValue] = StoredShortcut(first: commandT)
        let refreshed = model.actions(matching: query, keeping: shown)

        #expect(Array(refreshed.prefix(shown.count)) == shown)
        #expect(refreshed.contains(.newSurface))
        #expect(refreshed.contains(.openSettings))
        #expect(Set(refreshed).count == refreshed.count)
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

    @Test func recorderShowsCustomPromptIconAndTintWhileArmed() {
        let button = RecorderHostButton(frame: .zero)
        defer { button.cancelRecordingIfActive() }
        let resting = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        let recording = NSImage(systemSymbolName: "keyboard.badge.ellipsis", accessibilityDescription: nil)
        button.placeholder = "Detect Shortcut"
        button.recordingPrompt = "Listening…"
        button.restingImage = resting
        button.recordingImage = recording
        button.recordingTintColor = .controlAccentColor
        button.refreshTitle()
        #expect(button.title == "Detect Shortcut")
        #expect(button.image === resting)
        #expect(button.contentTintColor == nil)
        button.startRecording()
        #expect(button.title == "Listening…")
        #expect(button.image === recording)
        #expect(button.contentTintColor == .controlAccentColor)
        button.stopRecording()
        #expect(button.image === resting)
        #expect(button.contentTintColor == nil)
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
