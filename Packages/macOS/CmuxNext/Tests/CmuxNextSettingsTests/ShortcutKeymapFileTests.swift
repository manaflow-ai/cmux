import CmuxNextActions
import CmuxNextAppearance
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
        let settings = SettingsController(registry: .standard(), design: DesignSettings(), fileURL: url,
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
}
