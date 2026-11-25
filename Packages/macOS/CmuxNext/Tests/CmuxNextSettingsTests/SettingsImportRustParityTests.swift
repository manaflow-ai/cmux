import Foundation
@testable import CmuxNextSettings
import Testing

/// The import and migration logic moved to Rust (cmux-config `editor_import`, `migrations::classic`,
/// `migrations::renamed`; the `import.*`, `migrate.*` and `editor_toggle.*` ops). These pin what the
/// Swift code it replaced answered, so the move changes nothing a person sees.
struct SettingsImportRustParityTests {
    /// Every rename Swift listed by hand, with the old key it named.
    @Test func renamedKeysNameTheOldKeysSwiftNamed() {
        let expected: [[String]: [String]] = [
            ["appearance", "background"]: ["appearance", "backdropArt"],
            ["agentPane", "display", "sessionInfo", "placement"]: ["agentPane", "display", "inspector", "placement"],
            ["computerUse", "mode"]: ["computerUse", "enabled"],
            ["sidebar", "workspaceRow", "directory"]: ["sidebar", "showWorkspaceDirectory"],
            ["sidebar", "workspaceRow", "tabCount"]: ["sidebar", "showCounts"],
            ["remote", "ultra"]: ["remote", "ultraMode"],
        ]
        for (path, legacy) in expected { #expect(RenamedSettingKeys.legacyPath(for: path) == legacy, "\(path)") }
        #expect(RenamedSettingKeys.legacyPath(for: ["editor", "tabSize"]) == nil)
    }

    /// The old value reads as Swift read it: an old `enabled: false` is mode "off", a retired
    /// painting names its stand-in, an unknown one is "none", a plain rename reads as is.
    @Test func legacyValuesReadAsSwiftReadThem() {
        func value(_ path: [String], _ root: JSONValue) -> JSONValue? { RenamedSettingKeys.legacyValue(for: path, in: root) }
        #expect(value(["computerUse", "mode"], ["computerUse": ["enabled": false]]) == .string("off"))
        #expect(value(["computerUse", "mode"], ["computerUse": ["enabled": true]]) == nil)
        #expect(value(["appearance", "background"], ["appearance": ["backdropArt": "wheat-field-with-cypresses"]])
            == .string("van-gogh-wheat-field-cypresses"))
        #expect(value(["appearance", "background"], ["appearance": ["backdropArt": "no-such-work"]]) == .string("none"))
        #expect(value(["sidebar", "workspaceRow", "tabCount"], ["sidebar": ["showCounts": false]]) == .bool(false))
        #expect(value(["sidebar", "workspaceRow", "tabCount"], [:]) == nil)
    }

    /// `browser.import.enabled`: missing is the default, a bad value the default plus a diagnostic.
    @Test func browserImportParsesAsBefore() {
        #expect(BrowserImportSetting.parse([:]).0 == BrowserImportSetting.fallback)
        #expect(BrowserImportSetting.parse([:]).1 == nil)
        #expect(BrowserImportSetting.parse(["browser": ["import": ["enabled": false]]]).0 == false)
        let bad = BrowserImportSetting.parse(["browser": ["import": ["enabled": "no"]]])
        #expect(bad.0 == BrowserImportSetting.fallback)
        #expect(bad.1?.path == "browser.import.enabled")
        #expect(bad.1?.message == "expected true or false")
    }

    /// The editor choice, its files and the toggles as Swift had them.
    @Test func editorChoiceFilesAndTogglesMatch() {
        #expect(EditorImportChoice(setting: nil) == .auto)
        #expect(EditorImportChoice(setting: "none") == .none)
        #expect(EditorImportChoice(setting: "zed") == .editor(.zed))
        #expect(EditorImportChoice(setting: "emacs") == .auto)
        let sources = EditorSettingsSources(home: URL(filePath: "/Users/p"))
        #expect(sources.files(of: .vscode).settings.path == "/Users/p/Library/Application Support/Code/User/settings.json")
        #expect(sources.files(of: .zed).keys.path == "/Users/p/.config/zed/keymap.json")
        #expect(sources.watchedFiles(.auto).count == 10)
        #expect(sources.watchedFiles(.none).isEmpty)
        #expect(EditorPreferenceToggle.all.map(\.key) == ["editor.wordWrap", "editor.minimap.enabled"])
        #expect(EditorPreferenceToggle.wordWrap.next(in: ["wordWrap": "bounded"]) == .string("off"))
    }

    @Test func classicPreferenceKeysAreTheFourSwiftRead() {
        #expect(ClassicPreferenceImport.importedKey == "classicPreferencesImported")
        let keys = Set((ClassicPreferenceImport.layout["keys"]?.arrayValue ?? []).compactMap(\.stringValue))
        #expect(keys == ["browserDisabledOverride", "browserOpenTerminalLinksInCmuxBrowser", "browserHostWhitelist",
                         "browserExternalOpenPatterns"])
        #expect(ClassicPreferenceImport.pending([]))
    }
}
