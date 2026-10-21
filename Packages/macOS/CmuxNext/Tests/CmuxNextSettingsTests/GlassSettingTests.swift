import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Testing

/// `appearance.glass` (plans/cmux-next/glass-lens-DESIGN.md): Lens by default, Plain Glass and
/// Spectrum the other choices; a bad value keeps Lens and says why; the applier sets the live
/// setting; Settings > Appearance shows the three choices; agents may set it (a look only).
@MainActor @Suite struct GlassSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["appearance": .object(["glass": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func lensWhenUnset() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.glass == .lens)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test(arguments: [("lens", GlassLensMode.lens), ("plain", .plain), ("spectrum", .spectrum)])
    func eachChoiceLoads(raw: String, expected: GlassLensMode) {
        let snapshot = Self.parse(.string(raw))
        #expect(snapshot.glass == expected)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func aBadValueKeepsLensAndSaysWhy() {
        for bad: JSONValue in [.string("prism"), .bool(true)] {
            let snapshot = Self.parse(bad)
            #expect(snapshot.glass == .lens)
            #expect(snapshot.diagnostics.contains { $0.path == "appearance.glass" })
        }
    }

    @Test func theApplierSetsTheLiveSetting() {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry())
        _ = applier.apply(Self.parse(.string("spectrum")))
        #expect(design.glass == .spectrum)
        _ = applier.apply(Self.parse(nil))
        #expect(design.glass == .lens)
    }

    @Test func theRowOffersLensPlainAndSpectrumAndDefaultsToLens() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["appearance", "glass"]))
        #expect(row.section == .appearance)
        #expect(row.defaultValue == .string("lens"))
        guard case .choice(let choices) = row.kind else { Issue.record("not a choice row"); return }
        #expect(choices.map(\.value) == ["lens", "plain", "spectrum"])
        #expect(choices.map(\.titleKey) == ["settings.choice.glassLens", "settings.choice.glassPlain", "settings.choice.glassSpectrum"])
        #expect(SettingsSchema.agentSettableKeys.contains("appearance.glass"))
    }
}
