import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Testing
import Foundation

@MainActor
@Suite struct ModifierHoldHintsSettingTests {
    private func snapshot(_ root: JSONValue) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(root, validDensities: SettingsApplier.validDensities, validMetrics: SettingsApplier.validMetrics,
                                 configDirectory: URL(fileURLWithPath: "/tmp/cmux-hints-tests"))
    }

    @Test func appliesAndResetsTheClassicPreference() {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry.standard())
        let disabled = snapshot(["shortcuts": ["showModifierHoldHints": false]])
        #expect(disabled.diagnostics.isEmpty)
        _ = applier.apply(disabled)
        #expect(!design.showModifierHoldHints)
        _ = applier.apply(snapshot([:]))
        #expect(design.showModifierHoldHints)
    }

    @Test func rejectsInvalidValuesAndExposesTheToggle() {
        let bad = snapshot(["shortcuts": ["showModifierHoldHints": "true"]])
        #expect(bad.showModifierHoldHints)
        #expect(bad.diagnostics.contains { $0.path == "shortcuts.showModifierHoldHints" && $0.kind == .invalidValue })
        #expect(SettingsSchema.descriptor(for: ModifierHoldHintsSetting.configPath)?.section == .keyboard)
    }
}
