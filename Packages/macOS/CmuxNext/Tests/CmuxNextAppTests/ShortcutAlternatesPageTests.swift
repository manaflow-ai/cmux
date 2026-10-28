import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// The Keyboard Shortcuts page with an action that has several cmux.json keys
/// (`{"any": [...]}`, https://github.com/manaflow-ai/cmux/issues/25564): each key is a
/// row, and changing or removing a row changes that key alone in cmux.json.
@MainActor @Suite(.serialized) struct ShortcutAlternatesPageTests {
    private struct Fixture {
        let services: AppServices
        let url: URL

        /// `shortcuts.bindings.nextSurface` as written to cmux.json now.
        func written() throws -> Any? {
            let data = try Data(contentsOf: url)
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let bindings = (root?["shortcuts"] as? [String: Any])?["bindings"] as? [String: Any]
            return bindings?["nextSurface"]
        }

        /// nextSurface's keys in the binding table, as the page lists them.
        func rows() -> [KeyBinding] {
            RegistryKeyBindings(services.registry).table.entries.filter { $0.command == "nextSurface" }
        }

        func row(_ text: String) throws -> KeyBinding {
            try #require(rows().first { KeybindingReports.text($0.keys) == text }, "no nextSurface row on \(text)")
        }
    }

    private static func fixture() async throws -> (Fixture, URL) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-any-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"shortcuts":{"bindings":{"nextSurface":{"any":["ctrl+tab","cmd+]"]}}}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        services.settings = settings
        return (Fixture(services: services, url: url), directory)
    }

    /// What the page sends for a row: `{command, key, when, replaces}`.
    private static func params(_ row: KeyBinding, key: String? = nil) -> [String: CmuxNextSettings.JSONValue] {
        let when = row.when.map { CmuxNextSettings.JSONValue.string($0.text) } ?? .null
        let text = CmuxNextSettings.JSONValue.string(KeybindingReports.text(row.keys))
        var params: [String: CmuxNextSettings.JSONValue] = ["command": .string(row.command.rawValue), "when": when]
        if let key {
            params["key"] = .string(key)
            params["replaces"] = ["key": text, "when": when]
        } else {
            params["key"] = text
        }
        return params
    }

    @Test func eachKeyIsARowAndEditingOneKeepsTheOther() async throws {
        let (fixture, directory) = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(Set(fixture.rows().map { KeybindingReports.text($0.keys) }) == ["ctrl+tab", "cmd+]"])

        try await KeybindingEdit.set.run(Self.params(try fixture.row("cmd+]"), key: "cmd+ctrl+'"), services: fixture.services)
        #expect(try fixture.written() as? [String: [String]] == ["any": ["ctrl+tab", "cmd+ctrl+'"]])
        #expect(Set(fixture.rows().map { KeybindingReports.text($0.keys) }) == ["ctrl+tab", "cmd+ctrl+'"])

        try await KeybindingEdit.remove.run(Self.params(try fixture.row("ctrl+tab")), services: fixture.services)
        #expect(try fixture.written() as? String == "cmd+ctrl+'")
        #expect(fixture.rows().map { KeybindingReports.text($0.keys) } == ["cmd+ctrl+'"])
        #expect(fixture.services.registry.effectiveShortcut(for: "nextSurface") == Shortcut("'", modifiers: [.command, .control]))
    }
}
