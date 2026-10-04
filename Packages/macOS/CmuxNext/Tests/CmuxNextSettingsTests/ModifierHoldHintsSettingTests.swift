import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Testing

@MainActor
@Suite struct ModifierHoldHintsSettingTests {
    @Test func appliesAndResetsTheClassicPreference() {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry.standard())
        let disabled = CmuxConfigSnapshot.parse(["shortcuts": ["showModifierHoldHints": false]])
        #expect(disabled.diagnostics.isEmpty)
        _ = applier.apply(disabled)
        #expect(!design.showModifierHoldHints)
        _ = applier.apply(CmuxConfigSnapshot.parse([:]))
        #expect(design.showModifierHoldHints)
    }

    @Test func rejectsInvalidValuesAndExposesTheToggle() {
        let bad = CmuxConfigSnapshot.parse(["shortcuts": ["showModifierHoldHints": "true"]])
        #expect(bad.showModifierHoldHints)
        #expect(bad.diagnostics.contains { $0.path == "shortcuts.showModifierHoldHints" && $0.kind == .invalidValue })
        #expect(SettingsSchema.descriptor(for: ModifierHoldHintsSetting.configPath)?.section == .keyboard)
    }
}
