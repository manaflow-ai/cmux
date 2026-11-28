import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// The code editor takes its defaults from the person's other editor (Lawrence 2026-10-19: "read
/// user's vscode config or zed config ... to figure out defaults"). The mapping rules live in Rust
/// (cmux-config `editor_import_tests.rs` pins them); these check the Swift side reads the files Rust
/// names, layers cmux.json over the import, and copies through the one write path.
@MainActor @Suite struct EditorSettingsImportTests {
    /// A key set in cmux.json wins over the imported one; objects merge member by member.
    @Test func cmuxJSONWins() {
        let imported: JSONValue = ["tabSize": 2, "minimap": ["enabled": true], "wordWrap": "on"]
        let own: JSONValue = ["tabSize": 8, "minimap": ["side": "left"]]
        let section = EditorSettingsSources.section(imported: imported, own: own)
        #expect(section["tabSize"] == .number(8))
        #expect(section["wordWrap"] == "on")
        #expect(section["minimap"] == ["enabled": true, "side": "left"])
    }

    /// `auto` takes the first editor with a settings file, in the order VS Code, Cursor, Windsurf,
    /// VSCodium, Zed; `none` reads nothing; the files are only read.
    @Test func sourcesReadTheChosenEditorOnly() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-editor-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let sources = EditorSettingsSources(home: home)
        #expect(sources.load("auto") == nil)
        let zed = home.appending(path: ".config/zed/settings.json")
        try FileManager.default.createDirectory(at: zed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"tab_size\": 2, // Zed writes JSONC\n}".utf8).write(to: zed)
        let cursor = home.appending(path: "Library/Application Support/Cursor/User/settings.json")
        try FileManager.default.createDirectory(at: cursor.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"editor.tabSize": 3}"#.utf8).write(to: cursor)
        let before = try Data(contentsOf: cursor)

        #expect(sources.watchedFiles("zed").map(\.path) == [zed.path, home.appending(path: ".config/zed/keymap.json").path])
        #expect(sources.load("auto")?.name == "Cursor")
        #expect(sources.load("auto")?.section["tabSize"] == .number(3))
        #expect(sources.load("zed")?.section["tabSize"] == .number(2))
        #expect(sources.load("none") == nil)
        #expect(sources.load("vscode") == nil)
        #expect(try Data(contentsOf: cursor) == before)
        #expect(EditorSettingsSources.choice(setting: "zed") == "zed")
        #expect(EditorSettingsSources.choice(setting: "emacs") == "auto")
        #expect(EditorSettingsSources.choice(setting: nil) == "auto")
    }

    /// The page's toolbar toggles and Opt-Z write `editor.wordWrap` and `editor.minimap.enabled`
    /// through the one write path, which refused keys the schema did not list (the toggles reverted).
    /// The copy writes only keys cmux.json does not have.
    @Test func thePageTogglesAndTheCopyWriteThroughTheSchema() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-editor-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: "cmux-next.json")
        try Data(#"{"editor": {"tabSize": 8}}"#.utf8).write(to: url)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: .standard(), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        try await settings.setSetting(at: ["editor", "wordWrap"], to: "on", by: .caller("page"))
        try await settings.setSetting(at: ["editor", "minimap", "enabled"], to: .bool(true), by: .caller("page"))
        await #expect(throws: SettingUserOnly.self) {
            try await settings.setSetting(at: ["editor", "importFrom"], to: "zed", by: .caller("mcp"))
        }
        let imported: JSONValue = ["tabSize": 2, "wordWrap": "off", "fontSize": 14, "importFrom": "zed",
                                   "languages": ["python": ["tabSize": 4]]]
        let written = try await settings.copyEditorSettings(imported, by: .user)
        await settings.reload()
        #expect(written == 1)
        #expect(settings.fileRoot["editor"]?["tabSize"] == .number(8), "the copy replaced a key cmux.json had")
        #expect(settings.fileRoot["editor"]?["wordWrap"] == "on")
        #expect(settings.fileRoot["editor"]?["fontSize"] == .number(14))
        #expect(settings.fileRoot["editor"]?["languages"] == nil, "language blocks stay live, not copied")
    }
}
