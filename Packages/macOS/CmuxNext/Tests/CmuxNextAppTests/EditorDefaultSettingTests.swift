import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// cmux.json `editor.default`: an editor id of the table, or `auto` (the first editor found).
@MainActor
struct EditorDefaultSettingTests {
    @Test func theSettingReadsAnEditorIDOrAuto() {
        func editor(_ value: JSONValue?) -> String {
            let root: JSONValue = value.map { .object(["editor": .object(["default": $0])]) } ?? .object([:])
            let snapshot = CmuxConfigSnapshot.parse(root, validDensities: SettingsApplier.validDensities, validMetrics: SettingsApplier.validMetrics)
            return "\(snapshot.editorDefault.editor ?? "first") \(snapshot.diagnostics.filter { $0.path == "editor.default" }.count)"
        }
        #expect(editor(nil) == "first 0")
        #expect(editor(.string("auto")) == "first 0")
        #expect(editor(.string("zed")) == "zed 0")
        #expect(editor(.string("notepad")) == "first 1")
        #expect(editor(.number(3)) == "first 1")
        #expect(EditorDefaultSetting.configPath == ["editor", "default"])
    }
}
