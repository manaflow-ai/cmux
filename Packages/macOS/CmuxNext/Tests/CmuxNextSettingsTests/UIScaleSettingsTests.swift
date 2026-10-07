@testable import CmuxNextSettings
import CmuxNextActions
import CmuxNextDesign
import Foundation
import Testing

@Suite struct UIScaleSettingsTests {
    private let setting = UIScaleSetting()

    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func parsesTheAppScaleAndReportsOutOfRangeValues() throws {
        let valid = try parse(#"{"app":{"uiScale":1.25}}"#)
        #expect(valid.uiScale == 1.25)
        #expect(valid.diagnostics.isEmpty)

        let invalid = try parse(#"{"app":{"uiScale":2}}"#)
        #expect(invalid.uiScale == 2)
        #expect(invalid.diagnostics.map(\.path) == ["app.uiScale"])
    }

    @Test func appearanceSchemaExposesTheScale() {
        let descriptor = SettingsSchema.descriptor(for: setting.configPath)
        #expect(descriptor?.kind == .number(SettingNumber(setting.range, step: setting.step, unit: .fraction, placeholder: 1)))
        #expect(descriptor?.defaultValue == .number(setting.fallback))
        #expect(SettingsSchema.agentSettableKeys.contains("app.uiScale"))
    }

    @MainActor @Test func applierClampsTheLiveScale() {
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: registry)
        _ = applier.apply(CmuxConfigSnapshot(root: .object([:]), density: nil, metrics: [:], shortcuts: [:], diagnostics: []))
        #expect(design.uiScale == 1)
        var snapshot = CmuxConfigSnapshot.empty
        snapshot.uiScale = 2
        _ = applier.apply(snapshot)
        #expect(design.uiScale == 1.5)
    }
}
