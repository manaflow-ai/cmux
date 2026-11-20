import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Testing

/// `appearance.glass.composer.material` is the glass mode web pages draw (``GlassLensMode``), promoted from the
/// Debug choice `glass.lens` (Leo, 2026-11-20: "Like, why not offer the option? I think it looks neat. I like the
/// refraction."). Lens and spectrum are opt-in values; unset, plain or a native material draw plain glass.
@MainActor @Suite struct GlassLensSettingTests {
    private func applied(_ material: JSONValue?) -> GlassLensMode {
        let composer: [String: JSONValue] = material.map { ["material": $0] } ?? [:]
        let root: JSONValue = .object(["appearance": .object(["glass": .object(["composer": .object(composer)])])])
        let design = DesignSettings()
        design.glassLensMode = .spectrum
        _ = SettingsApplier(design: design, registry: ActionRegistry())
            .apply(CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []))
        return design.glassLensMode
    }

    @Test func theComposerMaterialPicksTheMode() {
        #expect(applied(.string("lens")) == .lens)
        #expect(applied(.string("spectrum")) == .spectrum)
        #expect(applied(.string("plain")) == .plain)
    }

    /// The default is today's look: no key (or a material the web draws as plain glass) is plain.
    @Test func unsetOrANativeMaterialIsPlainGlass() {
        #expect(applied(nil) == .plain)
        #expect(applied(.string("frosted")) == .plain)
        #expect(applied(.string("bogus")) == .plain)
    }

    @Test func theSettingOffersTheLensModesAndDefaultsToNothing() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: GlassSetting.composerMaterialPath))
        #expect(descriptor.defaultValue == nil)
        for mode in GlassLensMode.allCases { #expect(GlassSetting.composerMaterialValues.contains(mode.rawValue)) }
        #expect(SettingsSchema.agentSettableKeys.contains(GlassSetting.composerMaterialPath.joined(separator: ".")))
    }
}
