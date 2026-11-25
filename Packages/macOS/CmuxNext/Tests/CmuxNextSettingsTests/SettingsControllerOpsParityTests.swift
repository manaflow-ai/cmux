@testable import CmuxNextSettings
import Testing

/// The controller's load and edit decisions answer through cmux-config's `controller.*` ops
/// (cmux-tui/crates/cmux-config/src/app_ops/controller.rs, whose tests pin every case); these
/// check the Swift side reads the replies as the Swift code it replaced did.
struct SettingsControllerOpsParityTests {
    @Test func removingPrunedResetsThenDropsEachEmptiedParent() {
        #expect(SettingsController.removingPruned(["a", "b", "c"]) == [
            .reset(["a", "b", "c"]), .resetUnchanged(["a", "b"], .object([:])), .resetUnchanged(["a"], .object([:])),
        ])
        #expect(SettingsController.removingPruned(["a"]) == [.reset(["a"])])
    }

    @Test func applyingFollowsEachEditKind() {
        let root: JSONValue = ["a": ["b": 1, "c": [:]], "n": 2]
        #expect(SettingsController.applying([.set(["a", "b"], 5)], to: root) == ["a": ["b": 5, "c": [:]], "n": 2])
        #expect(SettingsController.applying([.setUnset(["a", "b"], 5)], to: root) == root)
        #expect(SettingsController.applying([.reset(["q", "r"])], to: root) == root)
        #expect(SettingsController.applying([.resetUnchanged(["n"], 2)], to: root) == ["a": ["b": 1, "c": [:]]])
        #expect(SettingsController.applying([.resetUnchanged(["n"], 3)], to: root) == root)
        #expect(SettingsController.applying(SettingsController.removingPruned(["a", "b"]) + [.reset(["a", "c"])], to: root)
            == ["a": [:], "n": 2])
    }

    @Test func aWireEditReadsBackAsItself() {
        for edit: SettingsFileEdit in [.set(["x"], "v"), .setUnset(["x", "y"], .null), .reset(["x"]), .resetUnchanged(["x"], [:])] {
            #expect(SettingsFileEdit(wire: edit.wire) == edit)
        }
    }

    @Test func seeThroughFollowsOpacityAndMaterial() {
        #expect(SettingsController.asksForSeeThrough(WindowBackgroundSetting.opacityPath, 0.5))
        #expect(!SettingsController.asksForSeeThrough(WindowBackgroundSetting.opacityPath, 1))
        #expect(SettingsController.asksForSeeThrough(WindowBackgroundSetting.materialPath, "regular"))
        #expect(!SettingsController.asksForSeeThrough(WindowBackgroundSetting.materialPath, "none"))
        #expect(!SettingsController.asksForSeeThrough(["appearance", "accent"], 0.1))
    }

    @Test func aDiagnosticReadsBackFromItsWire() {
        let diagnostic = SettingsDiagnostic(kind: .setByThemeFile, path: "appearance.accent", message: "m",
                                            file: "themes/tokyo.json", value: "\"teal\"")
        #expect(SettingsDiagnostic(wire: diagnostic.wire) == diagnostic)
        #expect(SettingsDiagnostic(wire: ["kind": "noSuchKind", "message": "m"]) == nil)
    }
}
