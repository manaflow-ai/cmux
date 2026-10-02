import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `focusRing.*` and `notifications.attention.*`.
@Suite struct PaneRingSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaults() throws {
        let snapshot = try parse("{}")
        #expect(snapshot.focusRing == FocusRingSettings())
        #expect(snapshot.focusRing.effectiveStyle == .ring)
        #expect(snapshot.focusRing.color == nil)
        #expect(snapshot.focusRing.cornerRadius == nil)
        #expect(!snapshot.focusRing.showsForSinglePane)
        #expect(snapshot.attention == AttentionSettings())
        #expect(snapshot.attention.style == .blink)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func readsEveryFocusRingField() throws {
        let ring = try parse(#"""
        {"focusRing": {"enabled": true, "style": "glow", "color": "#FF8800", "width": 3,
                       "cornerRadius": 12, "showWhenSinglePane": true}}
        """#).focusRing
        #expect(ring.style == .glow)
        #expect(ring.color == ThemeRGB(hex: 0xFF8800))
        #expect(ring.width == 3)
        #expect(ring.cornerRadius == 12)
        #expect(ring.showsForSinglePane)
        #expect(try parse(#"{"focusRing": {"enabled": false}}"#).focusRing.effectiveStyle == .none)
        #expect(try parse(#"{"focusRing": {"cornerRadius": "pane", "color": "theme"}}"#).focusRing.cornerRadius == nil)
    }

    @Test func badFocusRingValuesKeepDefaultsWithDiagnostics() throws {
        let snapshot = try parse(#"{"focusRing": {"style": "neon", "color": "blue", "width": 99, "enabled": "yes"}}"#)
        #expect(snapshot.focusRing.style == .ring)
        #expect(snapshot.focusRing.color == nil)
        #expect(snapshot.focusRing.width == FocusRingSettings.widthRange.upperBound)
        #expect(snapshot.focusRing.enabled)
        #expect(Set(snapshot.diagnostics.map(\.path)) == ["focusRing.style", "focusRing.color", "focusRing.width", "focusRing.enabled"])
    }

    @Test func readsFocusRingContrast() throws {
        #expect(try parse("{}").focusRing.contrast == .subtle)
        #expect(try parse(#"{"focusRing": {"contrast": "strong"}}"#).focusRing.contrast == .strong)
        let bad = try parse(#"{"focusRing": {"contrast": "loud"}}"#)
        #expect(bad.focusRing.contrast == .subtle)
        #expect(bad.diagnostics.map(\.path) == ["focusRing.contrast"])
        #expect(SettingsSchema.all.contains { $0.path == ["focusRing", "contrast"] })
    }

    @Test func readsAttention() throws {
        let attention = try parse(#"""
        {"notifications": {"attention": {"style": "pulse", "color": "#00FFAA", "width": 4, "blinkCount": 3,
                                         "duration": 5, "persist": false, "showOnTab": false, "showOnSidebar": false}}}
        """#).attention
        #expect(attention.style == .pulse)
        #expect(attention.color == ThemeRGB(hex: 0x00FFAA))
        #expect(attention.width == 4)
        #expect(attention.blinkCount == 3)
        #expect(attention.duration == 5)
        #expect(!attention.persists)
        #expect(!attention.showsOnTab)
        #expect(!attention.showsOnSidebar)
    }

    @Test func hexColorsParse() {
        #expect(ThemeRGB(cssHex: "#fff") == ThemeRGB(hex: 0xFFFFFF))
        #expect(ThemeRGB(cssHex: "112233") == ThemeRGB(hex: 0x112233))
        #expect(ThemeRGB(cssHex: "#11223380") == ThemeRGB(hex: 0x112233, alpha: Double(0x80) / 255))
        #expect(ThemeRGB(cssHex: "#12") == nil)
        #expect(ThemeRGB(cssHex: "#GGGGGG") == nil)
    }

    @MainActor @Test func appliesAndReverts() throws {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry.standard())
        applier.apply(try parse(#"{"focusRing": {"style": "glow"}, "notifications": {"attention": {"style": "none"}}}"#))
        #expect(design.focusRing.style == .glow)
        #expect(design.attention.style == .none)
        applier.apply(try parse("{}"))
        #expect(design.focusRing == FocusRingSettings())
        #expect(design.attention == AttentionSettings())
    }
}

/// `appearance.statusIndicator.*`.
@Suite struct StatusIndicatorSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsToTheThinThemeColoredArc() throws {
        let snapshot = try parse("{}")
        #expect(snapshot.statusIndicator == StatusIndicatorSettings())
        #expect(snapshot.statusIndicator.style == .arc)
        #expect(snapshot.statusIndicator.color == nil)
    }

    @Test func readsEveryField() throws {
        let settings = try parse(#"""
        {"appearance": {"statusIndicator": {"style": "native", "size": 0.8, "thickness": 2, "color": "#88AA44"}}}
        """#).statusIndicator
        #expect(settings.style == .native)
        #expect(settings.scale == 0.8)
        #expect(settings.thickness == 2)
        #expect(settings.color == ThemeRGB(hex: 0x88AA44))
    }

    @Test func invalidStyleKeepsTheDefaultAndOutOfRangeClamps() throws {
        let snapshot = try parse(#"{"appearance": {"statusIndicator": {"style": "rainbow", "thickness": 40}}}"#)
        #expect(snapshot.statusIndicator.style == .arc)
        #expect(snapshot.statusIndicator.thickness == StatusIndicatorSettings.thicknessRange.upperBound)
        #expect(snapshot.diagnostics.count == 2)
    }

    @MainActor @Test func appliesToDesignSettings() throws {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry.standard())
        applier.apply(try parse(#"{"appearance": {"statusIndicator": {"style": "dot"}}}"#))
        #expect(design.statusIndicator.style == .dot)
        applier.apply(try parse("{}"))
        #expect(design.statusIndicator == StatusIndicatorSettings())
    }

    @Test func schemaListsTheIndicatorSettings() {
        for key in ["style", "size", "thickness", "color"] {
            #expect(SettingsSchema.descriptor(for: ["appearance", "statusIndicator", key]) != nil)
        }
    }
}
