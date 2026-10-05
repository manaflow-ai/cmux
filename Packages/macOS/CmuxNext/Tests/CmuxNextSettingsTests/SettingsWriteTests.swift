import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// Settings window writes: validated against the schema, atomic, and a
/// reset removes the key plus the objects it leaves empty.
@MainActor
@Suite struct SettingsWriteTests {
    func controller(_ text: String) throws -> (SettingsController, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-settings-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(text.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url)
        return (settings, url)
    }

    func document(_ url: URL) throws -> JSONValue { try JSONC.parse(String(contentsOf: url, encoding: .utf8)) }

    @Test func writesValidValuesAndRemovesEmptiedObjects() async throws {
        let (settings, url) = try controller("{\n  // mine\n  \"actions\": {}\n}\n")
        let padding = try #require(SettingsSchema.descriptor(for: ["layout", "panePadding"]))
        try await settings.setSetting(padding, to: 8, by: .user)
        #expect(try document(url).value(at: ["layout", "panePadding"]) == 8)
        try await settings.setSetting(padding, to: nil, by: .user)
        #expect(try document(url)["layout"] == nil)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("// mine"))
    }

    @Test func refusesValuesTheSchemaRefuses() async throws {
        let (settings, url) = try controller("{}")
        let speed = try #require(SettingsSchema.descriptor(for: ["ui", "animationSpeed"]))
        await #expect(throws: SettingRefused.self) { try await settings.setSetting(speed, to: "warp", by: .user) }
        #expect(try document(url)["ui"] == nil)
    }

    @Test func resetAllKeepsWhatTheSchemaDoesNotOwn() async throws {
        let (settings, url) = try controller("""
        {
          "ui": { "animationSpeed": "off", "surfaceTabBar": { "buttons": [] } },
          "layout": { "paneBorder": "none" },
          "shortcuts": { "tiers": { "newTab": "global" }, "showModifierHoldHints": false, "bindings": { "newTab": "cmd+t" }, "splitRight": "cmd+\\\\" },
          "actions": { "hello": { "command": "echo hi" } }
        }
        """)
        try await settings.resetAllSettings(by: .user)
        let root = try document(url)
        #expect(root.value(at: ["ui", "animationSpeed"]) == nil)
        #expect(root.value(at: ["ui", "surfaceTabBar"]) != nil)
        #expect(root["layout"] == nil)
        #expect(root.value(at: ["shortcuts", "bindings"]) == nil)
        #expect(root.value(at: ["shortcuts", "splitRight"]) == nil)
        // `shortcuts.tiers` has no schema row and is not a shortcut override: it stays.
        #expect(root.value(at: ["shortcuts", "tiers", "newTab"]) == "global")
        // The hint toggle has a schema row (#17276): Reset All resets it.
        #expect(root.value(at: ["shortcuts", "showModifierHoldHints"]) == nil)
        #expect(root["actions"] != nil)
    }

    @Test func keymapImportExportUsesTheShortcutsObjectAndPreservesOtherKeys() async throws {
        let (settings, url) = try controller("""
        {
          // Keep this comment while a keymap is imported.
          "shortcuts": { "bindings": { "newTab": "cmd+t" } },
          "actions": { "hello": { "command": "echo hi" } }
        }
        """)
        #expect(try await settings.shortcutKeymap() == ["bindings": ["newTab": "cmd+t"]])

        try await settings.importShortcutKeymap(["shortcuts": [
            "bindings": ["newTab": "cmd+n", "closeTab": "cmd+w"],
            "tiers": ["newTab": "global"],
        ]])
        let root = try document(url)
        #expect(root.value(at: ["shortcuts", "bindings", "newTab"]) == "cmd+n")
        #expect(root.value(at: ["shortcuts", "bindings", "closeTab"]) == "cmd+w")
        #expect(root.value(at: ["shortcuts", "tiers", "newTab"]) == "global")
        #expect(root.value(at: ["actions", "hello", "command"]) == "echo hi")
        #expect(try String(contentsOf: url, encoding: .utf8).contains("Keep this comment"))
    }
}
