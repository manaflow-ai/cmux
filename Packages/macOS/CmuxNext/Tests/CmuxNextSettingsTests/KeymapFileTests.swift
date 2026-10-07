import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// Keymap files (the Keyboard Shortcuts page's Import Keymap… / Export
/// Keymap…, parity with the Swift Settings Keyboard section): an export
/// writes the `shortcuts` object; importing that file into another
/// cmux-next.json gives the same shortcuts and keeps its other keys.
@MainActor
struct KeymapFileTests {
    static func controller(_ text: String) throws -> (SettingsController, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-keymap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux-next.json")
        try Data(text.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        return (settings, url)
    }

    @Test func exportThenImportRoundTripsTheShortcuts() async throws {
        let (source, _) = try Self.controller(#"{ "shortcuts": { "bindings": { "newTab": "cmd+t", "closeTab": ["ctrl+b", "x"] }, "tiers": { "newTab": "system" } } }"#)
        let file = FileManager.default.temporaryDirectory.appending(path: "keymap-\(UUID().uuidString).json")
        try await source.exportShortcutKeymap(to: file)

        let (target, targetURL) = try Self.controller(#"{ "actions": { "hello": { "command": "echo hi" } } }"#)
        try await target.importShortcutKeymap(from: file)
        #expect(try await target.shortcutKeymap() == (try await source.shortcutKeymap()))
        let text = try String(contentsOf: targetURL, encoding: .utf8)
        #expect(text.contains("echo hi"), "other keys stay")
    }

    @Test func aBrokenFileIsRefusedAndChangesNothing() async throws {
        let (target, targetURL) = try Self.controller(#"{ "shortcuts": { "bindings": { "newTab": "cmd+t" } } }"#)
        let file = FileManager.default.temporaryDirectory.appending(path: "keymap-\(UUID().uuidString).json")
        try Data("[ not json".utf8).write(to: file)
        await #expect(throws: (any Error).self) { try await target.importShortcutKeymap(from: file) }
        #expect(try String(contentsOf: targetURL, encoding: .utf8).contains("cmd+t"))
    }
}
