import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextSettings
import Testing

/// `appearance.cornerFlush`, the corner treatment as a public setting (Leo, 2026-11-18: the gooey look "that we
/// don't have as default, but we have as a toggle maybe, and we can like do more stuff with that"). A theme file
/// or a setup sets it like any `appearance.*` key; a missing key keeps the default, flush with no goo (Leo,
/// 2026-11-13: "lawrence wanted no goo by default"); the Debug tunable `chrome.cornerFlush` still overrides it.
@MainActor @Suite(.serialized) struct CornerFlushSettingTests {
    func snapshot(_ appearance: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["appearance": .object(appearance)]), validDensities: SettingsApplier.validDensities,
                                 validMetrics: SettingsApplier.validMetrics)
    }

    /// `body` at Default density (compact keeps the pill under every value) over the shipped chrome, with no
    /// Debug Settings pick of `chrome.cornerFlush`, and the setting put back after.
    func withStockChrome<T>(_ body: () throws -> T) rethrows -> T {
        let design = DesignSettings.shared
        let before = (design.densityTokens, design.chromeStyle, design.cornerFlush)
        defer { (design.densityTokens, design.chromeStyle, design.cornerFlush) = before }
        design.densityTokens = DensityPreset.cozy.tokens
        design.chromeStyle = .flat
        let store = TunableStore.shared
        store.register([CornerFlush.tunable.descriptor])
        if !store.isActive { store.activate(file: nil) }
        let saved = store.override(CornerFlush.tunable.key)
        store.set(CornerFlush.tunable.key, nil)
        defer { store.set(CornerFlush.tunable.key, saved) }
        return try body()
    }

    /// The schema's default is flush, no goo, and a missing key leaves the default in effect.
    @Test func theDefaultIsFlushWithoutGoo() {
        #expect(CornerFlushSetting.fallback == .flush)
        #expect(CornerFlushSetting.fallback.feetRadius == 0)
        #expect(SettingsSchema.descriptor(for: CornerFlushSetting.configPath)?.defaultValue == .string("flush"))
        #expect(DesignSettings().cornerFlush == nil)
        #expect(CornerFlushSetting.effective(in: snapshot([:])) == nil)
        withStockChrome {
            SettingsApplier.applyPlacement(snapshot([:]), to: DesignSettings.shared)
            #expect(DesignSettings.shared.cornerFlush == nil)
            #expect(CornerFlush.current == .flush)
            #expect(!CornerFlush.isChosen)
        }
    }

    /// Each value reaches `CornerFlush.current` through the settings applier; a bad value is the default plus a
    /// diagnostic.
    @Test(arguments: CornerFlush.allCases)
    func theSettingDrivesTheCorner(_ value: CornerFlush) {
        withStockChrome {
            SettingsApplier.applyPlacement(snapshot(["cornerFlush": .string(value.rawValue)]), to: DesignSettings.shared)
            #expect(DesignSettings.shared.cornerFlush == value)
            #expect(CornerFlush.current == value)
            #expect(CornerFlush.isChosen == value.isOn)
        }
    }

    @Test func aBadValueIsTheDefaultWithADiagnostic() {
        let bad = snapshot(["cornerFlush": .string("goo")])
        #expect(CornerFlushSetting.effective(in: bad) == nil)
        #expect(bad.diagnostics.contains { $0.path == "appearance.cornerFlush" && $0.kind == .invalidValue })
    }

    /// A set value draws over a chrome the default does not fit (floating panes), as a Debug pick does; the
    /// Debug Settings tunable overrides the setting; compact density keeps the pill.
    @Test func aPickDrawsOverAnyChromeAndTheTunableOverridesIt() {
        withStockChrome {
            let design = DesignSettings.shared
            design.chromeStyle = .floating
            #expect(CornerFlush.current == .off, "the default keeps floating panes' cards")
            design.cornerFlush = .goo
            #expect(CornerFlush.current == .goo)
            #expect(CornerFlush.current.feetRadius > 0)
            _ = TunableStore.shared.set(CornerFlush.tunable.key, .choice(CornerFlush.tight.rawValue))
            #expect(CornerFlush.current == .tight, "the Debug Settings pick overrides the setting")
            _ = TunableStore.shared.set(CornerFlush.tunable.key, nil)
            design.densityTokens = .compact
            #expect(CornerFlush.current == .off, "compact keeps the pill")
        }
    }

    /// A theme file may carry it: it is an agent-settable look setting.
    @Test func aThemeFileMaySetIt() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: CornerFlushSetting.configPath))
        #expect(ThemeFileOverlay.isLook(descriptor))
        #expect(descriptor.isPaletteExposed)
    }
}
