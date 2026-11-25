import CmuxNextDesign
@testable import CmuxNextSettings
import CoreGraphics
import Testing

@MainActor struct UIScaleSettingTests {
    @Test(arguments: [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5])
    func presetsPassValidationAndKeepTheirScale(_ scale: Double) throws {
        let row = try #require(SettingsSchema.descriptor(for: UIScaleSetting.configPath))
        #expect(row.accepts(.number(scale)))
        var diagnostics: [SettingsDiagnostic] = []
        let parsed = UIScaleSetting().parse(.object(["app": .object(["uiScale": .number(scale)])]), diagnostics: &diagnostics)
        #expect(parsed == scale)
        #expect(diagnostics.isEmpty)
        #expect(DesignSettings.clampedUIScale(CGFloat(parsed)) == CGFloat(scale))
    }

    @Test(arguments: [(0.1, 0.25), (6.0, 5.0)])
    func outOfRangeValuesAreRefusedAndClamped(_ scale: Double, _ expected: Double) throws {
        let row = try #require(SettingsSchema.descriptor(for: UIScaleSetting.configPath))
        #expect(!row.accepts(.number(scale)))
        #expect(DesignSettings.clampedUIScale(CGFloat(scale)) == CGFloat(expected))
    }
}
