import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// `appearance.backgroundOpacity` and `appearance.backgroundBlur`: unset
/// keeps Ghostty's values (nil), a bad value keeps them too with a
/// diagnostic at its key, and the Settings window offers the slider and the
/// four materials.
@Suite struct WindowBackgroundSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func unsetKeepsGhosttysValues() throws {
        let snapshot = try parse("{}")
        #expect(snapshot.windowBackground == WindowBackgroundOverride())
        #expect(snapshot.diagnostics.isEmpty)
        #expect(CmuxConfigSnapshot.empty.windowBackground == WindowBackgroundOverride())
    }

    @Test func readsTheOpacityAndEveryMaterial() throws {
        #expect(try parse(#"{"appearance": {"backgroundOpacity": 0.65}}"#).windowBackground.opacity == 0.65)
        let expected: [String: WindowMaterialChoice] = ["frosted": .frosted, "glass": .glass, "glass-clear": .glassClear, "none": .unblurred]
        for (text, choice) in expected {
            let snapshot = try parse(#"{"appearance": {"backgroundBlur": "\#(text)"}}"#)
            #expect(snapshot.windowBackground.material == choice, "\(text)")
            #expect(snapshot.diagnostics.isEmpty)
        }
    }

    @Test func badValuesKeepGhosttysWithADiagnostic() throws {
        for (text, path) in [(#"{"appearance": {"backgroundOpacity": 1.5}}"#, "appearance.backgroundOpacity"),
                             (#"{"appearance": {"backgroundOpacity": "half"}}"#, "appearance.backgroundOpacity"),
                             (#"{"appearance": {"backgroundBlur": "mica"}}"#, "appearance.backgroundBlur"),
                             (#"{"appearance": {"backgroundBlur": 20}}"#, "appearance.backgroundBlur")] {
            let snapshot = try parse(text)
            #expect(snapshot.windowBackground == WindowBackgroundOverride(), "\(text)")
            #expect(snapshot.diagnostics.map(\.path) == [path], "\(text)")
        }
    }

    @Test func theAppearanceSectionHasTheSliderAndTheMaterials() throws {
        let opacity = try #require(SettingsSchema.descriptor(for: ["appearance", "backgroundOpacity"]))
        #expect(opacity.section == .appearance)
        guard case .number(let number) = opacity.kind else {
            Issue.record("backgroundOpacity is not a number")
            return
        }
        #expect(number.range == 0...1)
        #expect(number.step == 0.05)
        #expect(number.unit == .fraction)
        #expect(opacity.defaultValue == nil, "unset follows Ghostty, so the default window stays opaque")

        let material = try #require(SettingsSchema.descriptor(for: ["appearance", "backgroundBlur"]))
        guard case .choice(let choices) = material.kind else {
            Issue.record("backgroundBlur is not a choice")
            return
        }
        #expect(Set(choices.map(\.value)) == Set(WindowMaterialChoice.allCases.map(\.rawValue)))
        #expect(material.defaultValue == nil)
    }
}
