import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextSettings
@testable import CmuxNextTabs
import Testing

/// `appearance.gooeyTabs` (plans/cmux-next/gooey-tabs.md, "Levels"). Leo, 2026-11-23: "presumably a less intense
/// version should have a better case to be the default. so you guys need to try that. like. subtle goo." Off stays
/// the default and changes nothing; subtle and full resolve the corner to flush-goo and the tone to Subtle Tone as
/// effective values, never writing the user's own corner and tone settings.
@MainActor @Suite(.serialized) struct GooeyTabsSettingTests {
    func snapshot(_ appearance: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["appearance": .object(appearance)]), validDensities: SettingsApplier.validDensities,
                                 validMetrics: SettingsApplier.validMetrics)
    }

    /// `body` at Default density over the shipped chrome, with no Debug Settings pick of `chrome.cornerFlush`, and the
    /// settings it touches put back after.
    func withStockChrome<T>(_ body: () throws -> T) rethrows -> T {
        let design = DesignSettings.shared
        let before = (design.densityTokens, design.chromeStyle, design.cornerFlush, design.titleAreaTone, design.gooeyTabs)
        defer { (design.densityTokens, design.chromeStyle, design.cornerFlush, design.titleAreaTone, design.gooeyTabs) = before }
        design.densityTokens = DensityPreset.cozy.tokens
        design.chromeStyle = .flat
        let store = TunableStore.shared
        store.register([CornerFlush.tunable.descriptor])
        if !store.isActive { store.activate(file: nil) }
        let saved = store.overrides[CornerFlush.tunable.key]
        store.set(CornerFlush.tunable.key, nil)
        defer { store.set(CornerFlush.tunable.key, saved) }
        return try body()
    }

    @Test func theDefaultIsOff() {
        #expect(GooeyTabsSetting.fallback == .off)
        #expect(SettingsSchema.descriptor(for: GooeyTabsSetting.configPath)?.defaultValue == .string("off"))
        #expect(DesignSettings().gooeyTabs == .off)
        #expect(GooeyTabsSetting.effective(in: snapshot([:])) == .off)
        withStockChrome {
            SettingsApplier.applyPlacement(snapshot([:]), to: DesignSettings.shared)
            #expect(DesignSettings.shared.gooeyTabs == .off)
        }
    }

    @Test(arguments: GooeyTabs.allCases)
    func eachValueParsesAndApplies(_ level: GooeyTabs) {
        withStockChrome {
            let parsed = snapshot(["gooeyTabs": .string(level.rawValue)])
            #expect(GooeyTabsSetting.effective(in: parsed) == level)
            #expect(!parsed.diagnostics.contains { $0.path == "appearance.gooeyTabs" })
            SettingsApplier.applyPlacement(parsed, to: DesignSettings.shared)
            #expect(DesignSettings.shared.gooeyTabs == level)
        }
    }

    @Test func aBadValueIsTheDefaultWithADiagnostic() {
        let bad = snapshot(["gooeyTabs": .string("very")])
        #expect(GooeyTabsSetting.effective(in: bad) == .off)
        #expect(bad.diagnostics.contains { $0.path == "appearance.gooeyTabs" && $0.kind == .invalidValue })
    }

    /// Off leaves the corner and the tone exactly as the user's settings put them, for every combination.
    @Test(arguments: [CornerFlush?.none] + CornerFlush.allCases.map(Optional.some), TitleAreaTone.allCases)
    func offLeavesTheCornerAndTheToneAsTheyWere(_ corner: CornerFlush?, _ tone: TitleAreaTone) {
        withStockChrome {
            let design = DesignSettings.shared
            design.gooeyTabs = .off
            design.cornerFlush = corner
            design.titleAreaTone = tone
            #expect(CornerFlush.current == (corner ?? .flush))
            #expect(design.effectiveTitleAreaTone == tone)
        }
    }

    /// Subtle and full resolve to flush-goo over Subtle Tone without writing the user's settings, and going back to
    /// off restores what they set.
    @Test(arguments: [GooeyTabs.subtle, .full])
    func onResolvesToGooOverSubtleToneWithoutWritingTheSettings(_ level: GooeyTabs) {
        withStockChrome {
            let design = DesignSettings.shared
            design.cornerFlush = .off
            design.titleAreaTone = .oneColor
            SettingsApplier.applyPlacement(snapshot(["gooeyTabs": .string(level.rawValue), "cornerFlush": .string("off"),
                                                     "titleAreaTone": .string("oneColor")]), to: design)
            #expect(CornerFlush.current == .goo)
            #expect(CornerFlush.current.feetRadius > 0)
            #expect(design.effectiveTitleAreaTone == .subtleTone)
            #expect(Metrics.titleAreaShadeScale > 0, "the frame takes Subtle Tone's shade")
            #expect(design.cornerFlush == .off, "the corner setting is not written")
            #expect(design.titleAreaTone == .oneColor, "the tone setting is not written")
            SettingsApplier.applyPlacement(snapshot(["cornerFlush": .string("off"), "titleAreaTone": .string("oneColor")]), to: design)
            #expect(design.gooeyTabs == .off)
            #expect(CornerFlush.current == .off)
            #expect(design.effectiveTitleAreaTone == .oneColor)
            #expect(Metrics.titleAreaShadeScale == design.titleAreaContrast, "the pill's frame keeps the plain contrast")
        }
    }

    /// Compact density keeps the pill under every level, as it does under every corner.
    @Test func compactKeepsThePill() {
        withStockChrome {
            let design = DesignSettings.shared
            design.gooeyTabs = .full
            design.densityTokens = .compact
            #expect(CornerFlush.current == .off)
        }
    }

    @Test func itReachesEverySurface() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: GooeyTabsSetting.configPath))
        #expect(descriptor.isPaletteExposed)
        #expect(ThemeFileOverlay.isLook(descriptor))
    }
}

/// `GooTunables`: the goo knobs per level, defaulting to the contract's table and overridable live.
@MainActor @Suite(.serialized) struct GooTunablesTests {
    @Test func theDefaultsFollowTheContract() {
        #expect(GooTunables.tuning(for: .off) == GooTuning.off)
        #expect(GooTuning.off.stretch == 0 && GooTuning.off.wobbleAmplitude == 0)
        let subtle = GooTuning.subtle, full = GooTuning.full
        #expect(subtle.stretch == 0.12)
        #expect(full.stretch == 0.45)
        for spring in [subtle.select, subtle.open, subtle.close, subtle.reorder, subtle.snap, subtle.absorb, subtle.wobble] {
            #expect((0.86...0.9).contains(spring.dampingFraction))
        }
        for spring in [full.select, full.open, full.close, full.reorder, full.snap, full.absorb, full.wobble] {
            #expect((0.55...0.7).contains(spring.dampingFraction))
        }
        #expect(full.feetScale > subtle.feetScale, "full has wider fillets")
        #expect(full.breakDistance > subtle.breakDistance, "subtle's neck snaps early")
        for tuning in [subtle, full] { #expect(tuning.captureDistance < tuning.breakDistance) }
        #expect(subtle.wobbleAmplitude <= 1.5 && (2...4).contains(full.wobbleAmplitude))
    }

    @Test func everyKnobIsListedOncePerLevel() {
        let keys = GooTunables.all.map(\.key)
        #expect(Set(keys).count == keys.count)
        #expect(keys.count == 2 * (GooTunables.Event.allCases.count * 2 + GooTunables.Parameter.allCases.count))
        #expect(Set(GooTunables.subtle.descriptors.map(\.section.id)) == [GooTunables.subtleSection.id])
        #expect(Set(GooTunables.full.descriptors.map(\.section.id)) == [GooTunables.fullSection.id])
        let catalog = Set(TunableCatalog.all.map(\.key)) // through TabTunables.all
        #expect(keys.allSatisfy(catalog.contains), "Debug Settings lists every goo knob")
    }

    @Test func anOverrideAppliesLive() throws {
        let store = TunableStore.shared
        store.register(GooTunables.all)
        if !store.isActive { store.activate(file: nil) }
        let damping = try #require(GooTunables.full.dampings[.select])
        let stretch = try #require(GooTunables.subtle.parameters[.stretch])
        let saved = (store.overrides[damping.key], store.overrides[stretch.key])
        defer { store.set(damping.key, saved.0); store.set(stretch.key, saved.1) }
        #expect(GooTunables.tuning(for: .full) == GooTuning.full)
        store.set(damping.key, .number(0.4))
        store.set(stretch.key, .number(0.2))
        #expect(GooTunables.tuning(for: .full).select.dampingFraction == 0.4)
        #expect(GooTunables.tuning(for: .subtle).stretch == 0.2)
        #expect(GooTunables.tuning(for: .subtle).select == GooTuning.subtle.select)
    }
}
