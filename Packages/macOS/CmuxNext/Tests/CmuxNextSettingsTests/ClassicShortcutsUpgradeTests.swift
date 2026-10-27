import AppKit
import CmuxNextActions
import CmuxNextAppearance
@testable import CmuxNextSettings
import Foundation
import Testing

/// The update from classic cmux (hq#1870 parity audit, cx-x5bdq): shortcuts a
/// person recorded in classic's Settings lived in classic's preferences
/// (`shortcut.<action id>`), not in `cmux.json`. Next's launch import brings
/// them over once, under next's ID for a renamed action; a binding in
/// `cmux.json` wins, and a key next can't bind stays behind.
@MainActor @Suite(.serialized) struct ClassicShortcutsUpgradeTests {
    /// A shortcut as classic's Settings recorder stored it (`StoredShortcut`).
    static func stored(_ key: String, command: Bool = false, shift: Bool = false, option: Bool = false,
                       control: Bool = false, chordKey: String? = nil) throws -> Data {
        var object: [String: Any] = ["key": key, "command": command, "shift": shift, "option": option, "control": control,
                                     "chordCommand": false, "chordShift": false, "chordOption": false, "chordControl": false]
        object["chordKey"] = chordKey
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func classicRecordedShortcutsComeOverOnTheUpdate() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-classic-shortcuts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data(#"{ "shortcuts": { "bindings": { "nextSurface": "cmd+ctrl+n" } } }"#.utf8).write(to: url)

        // The stable channel never recorded one; the person used nightly.
        let names = ["stable", "nightly", "next"].map { "cn-classic-shortcuts-\($0)-\(UUID().uuidString)" }
        defer { names.forEach(UserDefaults().removePersistentDomain(forName:)) }
        let stable = try #require(UserDefaults(suiteName: names[0]))
        let nightly = try #require(UserDefaults(suiteName: names[1]))
        let next = try #require(UserDefaults(suiteName: names[2]))
        nightly.set(try Self.stored("b", command: true, option: true, control: true), forKey: "shortcut.toggleSidebar")
        nightly.set(try Self.stored("h", command: true, option: true, control: true), forKey: "shortcut.showWindowHints")
        nightly.set(try Self.stored("b", control: true, chordKey: "p"), forKey: "shortcut.commandPalette")
        nightly.set(try Self.stored(""), forKey: "shortcut.closeTab")
        nightly.set(try Self.stored("k", command: true, option: true), forKey: "shortcut.nextSurface")
        nightly.set(try Self.stored("media.playpause"), forKey: "shortcut.focusLeft")
        // Next routes only Command and Control keys; Option-L would never fire.
        nightly.set(try Self.stored("l", option: true), forKey: "shortcut.focusRight")
        // Classic's stored Cmd-J is next's leader; Cmd-, is next's Settings.
        nightly.set(try Self.stored("j", command: true), forKey: "shortcut.newWindow")
        nightly.set(try Self.stored(",", command: true), forKey: "shortcut.toggleFullScreen")

        let defaults = ActionRegistry.standard()
        let settings = SettingsController(registry: .standard(), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()),
                                          managedWatchFiles: [])
        await settings.reload()
        try await settings.importClassicShortcuts(from: [stable, nightly], marker: next)
        let registry = settings.applier.registry

        #expect(registry.effectiveShortcut(for: "toggleSidebar") == Shortcut("b", modifiers: [.command, .option, .control]))
        // Classic's Show Window Hints is next's hints.show.
        #expect(registry.effectiveShortcut(for: "hints.show") == Shortcut("h", modifiers: [.command, .option, .control]))
        #expect(registry.chordOverrides["commandPalette"] == ShortcutChord(Shortcut("b", modifiers: [.control]),
                                                                          Shortcut("p", modifiers: [])))
        #expect(registry.effectiveShortcut(for: "closeTab") == nil)
        // cmux.json already binds it; a key next can't bind stays behind.
        #expect(registry.effectiveShortcut(for: "nextSurface") == Shortcut("n", modifiers: [.command, .control]))
        #expect(registry.effectiveShortcut(for: "focusLeft") == defaults.effectiveShortcut(for: "focusLeft"))
        for id: ActionID in ["focusRight", "newWindow", "toggleFullScreen"] {
            #expect(registry.effectiveShortcut(for: id) == defaults.effectiveShortcut(for: id), "\(id)")
        }

        // Reset in next, then the next launch: the classic shortcut does not come back.
        try await settings.resetShortcut(for: "toggleSidebar")
        try await settings.importClassicShortcuts(from: [stable, nightly], marker: next)
        #expect(registry.effectiveShortcut(for: "toggleSidebar") == defaults.effectiveShortcut(for: "toggleSidebar"))
    }
}
