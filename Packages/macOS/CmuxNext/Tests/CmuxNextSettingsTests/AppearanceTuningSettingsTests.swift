import CmuxNextDesign
import CmuxNextSettings
import Testing

@Suite struct AppearanceTuningSettingsTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func absentAxesUseIdentityAndGateIsOff() throws {
        let snapshot = try parse("{}")
        #expect(snapshot.appearanceTuning == .identity)
        #expect(!snapshot.experimentalAppearance)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func readsAllAxesIndependently() throws {
        let snapshot = try parse(#"{"appearance":{"glassTransparency":0.35,"hue":0.8,"saturation":1.6,"experimentalControls":true}}"#)
        #expect(snapshot.appearanceTuning == AppearanceTuning(glassTransparency: 0.35, hue: 0.8, saturation: 1.6))
        #expect(snapshot.experimentalAppearance)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func invalidAxesKeepTheirIdentityAndDiagnoseEachKey() throws {
        let snapshot = try parse(#"{"appearance":{"glassTransparency":-0.1,"hue":"warm","saturation":2.1}}"#)
        #expect(snapshot.appearanceTuning == .identity)
        #expect(snapshot.diagnostics.map(\.path).sorted() == [
            "appearance.glassTransparency", "appearance.hue", "appearance.saturation",
        ])
    }

    @Test func descriptorsExposeThePersistedRangesAndDefaults() throws {
        let transparency = try #require(SettingsSchema.descriptor(for: AppearanceTuningSetting.glassTransparencyPath))
        let hue = try #require(SettingsSchema.descriptor(for: AppearanceTuningSetting.huePath))
        let saturation = try #require(SettingsSchema.descriptor(for: AppearanceTuningSetting.saturationPath))
        #expect(transparency.defaultValue == .number(0))
        #expect(hue.defaultValue == .number(0.5))
        #expect(saturation.defaultValue == .number(1))
        guard case .number(let transparencyNumber) = transparency.kind,
              case .number(let hueNumber) = hue.kind,
              case .number(let saturationNumber) = saturation.kind else {
            Issue.record("appearance tuning axes must be numeric settings")
            return
        }
        #expect(transparencyNumber.range == 0...1)
        #expect(hueNumber.range == 0...1)
        #expect(saturationNumber.range == 0...2)
    }

    @Test func backgroundAcceptsBundledAndAbsoluteSystemSelections() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["appearance", "background"]))
        #expect(descriptor.accepts(.string("none")))
        #expect(descriptor.accepts(.string("wheat-field-with-cypresses")))
        #expect(descriptor.accepts(.string("system:/System/Library/Desktop Pictures/Solid Colors/Blue.heic")))
        #expect(!descriptor.accepts(.string("system:relative/path.heic")))
        #expect(!descriptor.accepts(.string("system:")))
    }

    @Test func backgroundParserKeepsTheSameSelectionDomain() throws {
        let system = try parse(#"{"appearance":{"background":"system:/System/Library/Desktop Pictures/Solid Colors/Blue.heic"}}"#)
        #expect(system.backdropSelection == .system(path: "/System/Library/Desktop Pictures/Solid Colors/Blue.heic"))
        #expect(system.diagnostics.isEmpty)

        let invalid = try parse(#"{"appearance":{"background":"system:relative/path.heic"}}"#)
        #expect(invalid.backdropSelection == nil)
        #expect(invalid.diagnostics.map(\.path) == ["appearance.background"])
    }

    @Test func legacyBackdropArtStillParsesAndHasAResettableDescriptor() throws {
        let snapshot = try parse(#"{"appearance":{"backdropArt":"wheat-field-with-cypresses"}}"#)
        #expect(snapshot.backdropSelection == .art(.wheatField))
        #expect(snapshot.backdropArt == .wheatField)
        #expect(SettingsSchema.descriptor(for: ["appearance", "backdropArt"]) != nil)
    }
}
