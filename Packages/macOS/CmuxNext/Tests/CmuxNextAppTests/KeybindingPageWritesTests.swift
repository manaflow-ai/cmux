import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The Keyboard Shortcuts page saves shortcuts (slice 4 on cmux.json): set,
/// remove and reset write `shortcuts.bindings.<id>` through the settings
/// writer, with the palette recorder's assessment (refusals and same-place
/// conflicts are errors); Ghostty rows stay read-only.
@MainActor @Suite(.serialized) struct KeybindingPageWritesTests {
    static func writes() throws -> (KeybindingPageWrites, ActionRegistry, URL) {
        let registry = KeybindingReportTests.registry()
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-keys-page-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}\n".utf8).write(to: url)
        let settings = SettingsController(registry: registry, design: DesignSettings(), fileURL: url)
        return (KeybindingPageWrites(registry: registry, settings: settings), registry, url)
    }

    static func binding(_ url: URL, _ id: String) throws -> JSONValue? {
        try JSONC.parse(String(contentsOf: url, encoding: .utf8)).value(at: ["shortcuts", "bindings", id])
    }

    static func code(_ body: () async throws -> Void) async -> String? {
        do { try await body(); return nil } catch let error as PageError { return error.code } catch { return "\(error)" }
    }

    @Test func setWritesTheKeyAndTheTableFollows() async throws {
        let (writes, registry, url) = try Self.writes()
        try await writes.set(["command": "splitRight", "key": "cmd+ctrl+y", "replaces": ["key": "cmd+d", "when": .null]])
        let value = try #require(try Self.binding(url, "splitRight"))
        #expect(ShortcutBindingFormat.parse(value) == .stroke(ShortcutStrokeSpec(key: "y", command: true, control: true)))
        #expect(registry.effectiveShortcut(for: "splitRight") == Shortcut("y", modifiers: [.command, .control]))
    }

    @Test func aTwoKeyChordIsWrittenAsAnArray() async throws {
        let (writes, _, url) = try Self.writes()
        try await writes.set(["command": "splitRight", "key": "ctrl+b c"])
        #expect(try Self.binding(url, "splitRight").flatMap(ShortcutBindingFormat.parse)
            == .chord(ShortcutStrokeSpec(key: "b", control: true), ShortcutStrokeSpec(key: "c")))
    }

    @Test func removeUnbindsAndResetRestoresTheDefault() async throws {
        let (writes, registry, url) = try Self.writes()
        try await writes.remove(["command": "splitRight", "key": "cmd+d", "when": .null])
        #expect(try Self.binding(url, "splitRight") == .null)
        #expect(registry.effectiveShortcut(for: "splitRight") == nil)
        try await writes.reset(["command": "splitRight"])
        #expect(try Self.binding(url, "splitRight") == nil)
        #expect(registry.effectiveShortcut(for: "splitRight") == Shortcut("d", modifiers: [.command]))
    }

    /// The recorder's refusals and same-place conflicts are errors; the file does not change.
    @Test func refusalsAndSamePlaceConflictsAreNotWritten() async throws {
        let (writes, _, url) = try Self.writes()
        #expect(await Self.code { try await writes.set(["command": "splitRight", "key": "d"]) } == "cmux.keybindings.refused")
        #expect(await Self.code { try await writes.set(["command": "splitRight", "key": "cmd+t"]) } == "cmux.keybindings.conflict")
        #expect(try Self.binding(url, "splitRight") == nil)
    }

    /// Ghostty rows are the user's Ghostty config: never written.
    @Test func ghosttyRowsAreReadOnly() async throws {
        let (writes, registry, url) = try Self.writes()
        let key = Shortcut("d", modifiers: [.command])
        KeyBindingLoader(registry).loadGhostty([
            KeyBinding(keys: [key], command: "splitDown", when: GhosttyKeyBindingLayer.terminalFocused, source: .ghostty),
        ])
        let when = JSONValue.string(GhosttyKeyBindingLayer.terminalFocused.text)
        #expect(await Self.code { try await writes.remove(["command": "splitDown", "key": "cmd+d", "when": when]) }
            == "cmux.keybindings.read_only")
        #expect(try Self.binding(url, "splitDown") == nil)
    }
}
