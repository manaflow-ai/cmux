import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// A keymap file exported from one settings file imports into another unchanged (the file read and write run
/// off the main actor; the controller is main-actor).
@MainActor @Suite(.serialized) struct ShortcutKeymapFileTests {
    static func settings(_ json: String) throws -> (SettingsController, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-keymap-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: .standard(), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()),
                                          managedWatchFiles: [])
        return (settings, home)
    }

    @Test func anExportedKeymapImportsIntoAnotherFile() async throws {
        let (source, sourceHome) = try Self.settings("{}")
        let (target, targetHome) = try Self.settings("{}")
        defer {
            try? FileManager.default.removeItem(at: sourceHome)
            try? FileManager.default.removeItem(at: targetHome)
        }
        await source.reload()
        await target.reload()
        let file = sourceHome.appending(path: "keymap.json")
        try await source.exportShortcutKeymap(to: file)
        #expect(FileManager.default.fileExists(atPath: file.path))
        try await target.importShortcutKeymap(from: file)
        #expect(try await target.shortcutKeymap() == source.shortcutKeymap())
    }

    /// The key style and keyboard layout travel with the shortcuts; other `app` keys in a shared
    /// file are left alone.
    @Test func aKeymapCarriesTheKeyStyleAndLayout() async throws {
        let (source, sourceHome) = try Self.settings(#"{"app": {"keyStyle": "vim", "shortcutLayout": "qwertyPositions", "uiScale": 1.2}, "shortcuts": {"bindings": {"newTab": "cmd+shift+t"}}}"#)
        let (target, targetHome) = try Self.settings(#"{"app": {"uiScale": 0.9}}"#)
        defer {
            try? FileManager.default.removeItem(at: sourceHome)
            try? FileManager.default.removeItem(at: targetHome)
        }
        await source.reload()
        await target.reload()
        let file = sourceHome.appending(path: "keymap.json")
        try await source.exportShortcutKeymap(to: file)
        let exported = try JSONC.parse(String(contentsOf: file, encoding: .utf8))
        #expect(exported.value(at: ["app", "keyStyle"]) == .string("vim"))
        #expect(exported.value(at: ["app", "uiScale"]) == nil)
        try await target.importShortcutKeymap(from: file)
        #expect(target.snapshot.keyboardStyle.keyStyle == .vim)
        #expect(target.snapshot.keyboardStyle.shortcutLayout == .qwertyPositions)
        #expect(target.snapshot.browserVimKeys)
        #expect(try await target.file.value(at: ["app", "uiScale"]) == .number(0.9))
        #expect(try await target.shortcutKeymap() == source.shortcutKeymap())
    }

    /// A file with only the `app` keys sets them and writes no bindings.
    @Test func anAppOnlyKeymapWritesNoBindings() async throws {
        let (target, home) = try Self.settings("{}")
        defer { try? FileManager.default.removeItem(at: home) }
        await target.reload()
        try await target.importShortcutKeymap(.object(["app": .object(["keyStyle": .string("emacs")])]))
        await target.reload()
        #expect(target.snapshot.keyboardStyle.keyStyle == .emacs)
        #expect(try await target.file.value(at: ["shortcuts"]) == nil)
    }
}
