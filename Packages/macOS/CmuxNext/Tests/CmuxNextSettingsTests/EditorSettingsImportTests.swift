import CmuxNextActions
import CmuxNextAppearance
@testable import CmuxNextSettings
import Foundation
import Testing

/// The code editor takes its defaults from the person's other editor (Lawrence 2026-10-19: "read
/// user's vscode config or zed config ... to figure out defaults"): VS Code's and Zed's files map to
/// the `editor` section; a key set in cmux.json wins; the other editor's files are only read.
@MainActor @Suite struct EditorSettingsImportTests {
    static let vscodeSettings = """
    {
      // VS Code writes JSONC: comments and trailing commas.
      "editor.fontFamily": "JetBrains Mono, Menlo",
      "editor.fontSize": 14,
      "editor.tabSize": 2,
      "editor.wordWrap": "on",
      "editor.minimap.enabled": false,
      "editor.rulers": [80, {"column": 120, "color": "#ff0000"}],
      "editor.fontLigatures": "'ss01', 'calt'",
      "editor.fontWeight": "480",
      "editor.cursorStyle": "block",
      "editor.lineNumbers": "relative",
      "editor.autoClosingBrackets": "never",
      "editor.quickSuggestions": {"other": "on", "comments": "off"},
      "editor.wordBasedSuggestions": "off",
      "editor.guides.bracketPairs": "active",
      "editor.bogusKey": 1,
      "editor.lineHeight": 9999,
      "files.autoSave": "onFocusChange",
      "files.trimTrailingWhitespace": true,
      "workbench.colorTheme": "Default Dark+",
      "[python]": {"editor.tabSize": 4, "editor.insertSpaces": true, "editor.rulers": [88]},
      "[typescript][javascript]": {"editor.formatOnSave": true},
    }
    """

    static let vscodeKeys = """
    [
      {"key": "cmd+shift+l", "command": "editor.action.selectHighlights", "when": "editorFocus"},
      {"key": "cmd+k cmd+0", "command": "-editor.foldAll"},
      {"key": "cmd+b", "command": "workbench.action.toggleSidebarVisibility"},
      {"key": "cmd+u", "command": "cursorUndo"},
    ]
    """

    @Test func vsCodeSettingsMapToTheEditorSection() throws {
        let section = EditorSettingsImport().vscode(settings: try JSONC.parse(Self.vscodeSettings), keybindings: try JSONC.parse(Self.vscodeKeys))
        #expect(section["fontFamily"] == "JetBrains Mono, Menlo")
        #expect(section["fontSize"] == .number(14))
        #expect(section["tabSize"] == .number(2))
        #expect(section["wordWrap"] == "on")
        #expect(section["minimap"]?["enabled"] == .bool(false))
        #expect(section["rulers"] == .array([.number(80), .number(120)]))
        #expect(section["fontLigatures"] == .bool(true))
        #expect(section["fontWeight"] == "500", "480 maps to the nearest weight the row offers")
        #expect(section["cursorStyle"] == "block")
        #expect(section["lineNumbers"] == "relative")
        #expect(section["autoClosingBrackets"] == .bool(false))
        #expect(section["quickSuggestions"] == .bool(true))
        #expect(section["wordBasedSuggestions"] == .bool(false))
        #expect(section["guides"]?["bracketPairs"] == .bool(true))
        #expect(section["bogusKey"] == nil, "a key the editor does not read comes over")
        #expect(section["lineHeight"] == nil, "a value outside the row's range comes over")
        #expect(section["autoSave"] == "afterDelay")
        #expect(section["trimTrailingWhitespace"] == .bool(true))
        #expect(section["colorTheme"] == nil)
        #expect(section["languages"]?["python"]?["tabSize"] == .number(4))
        #expect(section["languages"]?["python"]?["rulers"] == .array([.number(88)]))
        #expect(section["languages"]?["typescript"]?["formatOnSave"] == .bool(true))
        #expect(section["languages"]?["javascript"]?["formatOnSave"] == .bool(true))
        let keys = section["keybindings"]?.arrayValue ?? []
        #expect(keys.compactMap { $0["command"]?.stringValue } == ["editor.action.selectHighlights", "-editor.foldAll", "cursorUndo"],
                "only editor commands come over")
        #expect(keys.first?["when"] == "editorFocus")
    }

    /// Every value the mapping makes is one the Settings row accepts, so copying it into cmux.json
    /// loads without a diagnostic.
    @Test func everyMappedValueIsOneItsRowAccepts() throws {
        let section = EditorSettingsImport().vscode(settings: try JSONC.parse(Self.vscodeSettings), keybindings: nil)
        for descriptor in EditorSettingsSchema.descriptors {
            guard let value = section.value(at: Array(descriptor.path.dropFirst())) else { continue }
            #expect(descriptor.accepts(value), "\(descriptor.id) = \(value)")
        }
    }

    static let zedSettings = """
    {
      "buffer_font_family": "Berkeley Mono",
      "buffer_font_size": 15,
      "buffer_font_weight": 400,
      "buffer_line_height": "comfortable",
      "tab_size": 2,
      "hard_tabs": true,
      "soft_wrap": "preferred_line_length",
      "preferred_line_length": 100,
      "wrap_guides": [100],
      "relative_line_numbers": true,
      "cursor_blink": false,
      "cursor_shape": "hollow",
      "show_whitespaces": "all",
      "minimap": {"show": "never"},
      "remove_trailing_whitespace_on_save": false,
      "autosave": {"after_delay": {"milliseconds": 500}},
      "vim_mode": true,
      "languages": {"Python": {"tab_size": 4}, "Shell Script": {"hard_tabs": true}},
    }
    """

    static let zedKeymap = """
    [
      {"context": "Editor", "bindings": {"cmd-shift-l": "editor::SelectAllMatches", "cmd-j": ["editor::Fold", {}], "cmd-y": "workspace::Unknown"}},
      {"context": "Terminal", "bindings": {"cmd-k": "editor::DeleteLine"}},
    ]
    """

    @Test func zedSettingsMapToTheEditorSection() throws {
        let section = EditorSettingsImport().zed(settings: try JSONC.parse(Self.zedSettings), keymap: try JSONC.parse(Self.zedKeymap))
        #expect(section["fontFamily"] == "Berkeley Mono")
        #expect(section["fontSize"] == .number(15))
        #expect(section["fontWeight"] == "normal")
        #expect(section["lineHeight"] == .number(1.618))
        #expect(section["tabSize"] == .number(2))
        #expect(section["insertSpaces"] == .bool(false))
        #expect(section["wordWrap"] == "wordWrapColumn")
        #expect(section["wordWrapColumn"] == .number(100))
        #expect(section["rulers"] == .array([.number(100)]))
        #expect(section["lineNumbers"] == "relative")
        #expect(section["cursorBlinking"] == "solid")
        #expect(section["cursorStyle"] == "block-outline")
        #expect(section["renderWhitespace"] == "all")
        #expect(section["minimap"]?["enabled"] == .bool(false))
        #expect(section["trimTrailingWhitespace"] == .bool(false))
        #expect(section["autoSave"] == "afterDelay")
        #expect(section["autoSaveDelay"] == .number(500))
        #expect(section["languages"]?["python"]?["tabSize"] == .number(4))
        #expect(section["languages"]?["shellscript"]?["insertSpaces"] == .bool(false))
        let keys = section["keybindings"]?.arrayValue ?? []
        #expect(keys.contains(["key": "cmd-shift-l", "command": "editor.action.selectHighlights"]))
        #expect(keys.contains(["key": "cmd-j", "command": "editor.fold"]))
        #expect(keys.count == 2, "a Terminal binding or an action with no Monaco command came over")
    }

    /// A key set in cmux.json wins over the imported one; objects merge member by member.
    @Test func cmuxJSONWins() {
        let imported: JSONValue = ["tabSize": 2, "minimap": ["enabled": true], "wordWrap": "on"]
        let own: JSONValue = ["tabSize": 8, "minimap": ["side": "left"]]
        let section = EditorSettingsImport.section(imported: imported, own: own)
        #expect(section["tabSize"] == .number(8))
        #expect(section["wordWrap"] == "on")
        #expect(section["minimap"] == ["enabled": true, "side": "left"])
    }

    /// A dotted key with no member name in it sets nothing; it trapped in `removeFirst` on an empty
    /// split before (p10-stability-097). Empty segments between dots are skipped, as before.
    @Test func aKeyWithNoMemberNameSetsNothing() {
        var section: [String: JSONValue] = ["tabSize": 2]
        EditorSettingsImport.set(&section, "", true)
        EditorSettingsImport.set(&section, ".", true)
        EditorSettingsImport.set(&section, "..", true)
        #expect(section == ["tabSize": 2])
        EditorSettingsImport.set(&section, "minimap..enabled", false)
        #expect(section["minimap"] == ["enabled": false])
        EditorSettingsImport.set(&section, "wordWrap", "on")
        #expect(section["wordWrap"] == "on")
    }

    /// `auto` takes the first editor with a settings file, in the order VS Code, Cursor, Windsurf,
    /// VSCodium, Zed; `none` reads nothing; the files are only read.
    @Test func sourcesReadTheChosenEditorOnly() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-editor-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let sources = EditorSettingsSources(home: home)
        #expect(sources.load(.auto) == nil)
        let zed = sources.files(of: .zed)
        try FileManager.default.createDirectory(at: zed.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.zedSettings.utf8).write(to: zed.settings)
        let cursor = sources.files(of: .cursor)
        try FileManager.default.createDirectory(at: cursor.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"editor.tabSize": 3}"#.utf8).write(to: cursor.settings)
        let before = try Data(contentsOf: cursor.settings)

        #expect(sources.load(.auto)?.editor == .cursor)
        #expect(sources.load(.auto)?.section["tabSize"] == .number(3))
        #expect(sources.load(.editor(.zed))?.section["tabSize"] == .number(2))
        #expect(sources.load(.none) == nil)
        #expect(sources.load(.editor(.vscode)) == nil)
        #expect(try Data(contentsOf: cursor.settings) == before)
        #expect(EditorImportChoice(setting: "zed") == .editor(.zed))
        #expect(EditorImportChoice(setting: "emacs") == .auto)
        #expect(EditorImportChoice(setting: nil) == .auto)
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
        let settings = SettingsController(registry: .standard(), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        try await settings.setSetting(at: ["editor", "wordWrap"], to: "on", by: .caller("page"))
        try await settings.setSetting(at: ["editor", "minimap", "enabled"], to: .bool(true), by: .caller("page"))
        await #expect(throws: SettingUserOnly.self) {
            try await settings.setSetting(at: ["editor", "importFrom"], to: "zed", by: .caller("mcp"))
        }
        let imported = EditorSettingsImport().vscode(settings: try JSONC.parse(Self.vscodeSettings), keybindings: nil)
        let written = try await settings.copyEditorSettings(imported, by: .user)
        await settings.reload()
        #expect(written > 5)
        #expect(settings.fileRoot["editor"]?["tabSize"] == .number(8), "the copy replaced a key cmux.json had")
        #expect(settings.fileRoot["editor"]?["wordWrap"] == "on")
        #expect(settings.fileRoot["editor"]?["fontSize"] == .number(14))
        #expect(settings.fileRoot["editor"]?["languages"] == nil, "language blocks stay live, not copied")
    }
}
