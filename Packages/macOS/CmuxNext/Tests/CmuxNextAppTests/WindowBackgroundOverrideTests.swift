import CmuxNextDesign
import CmuxNextSettings
import Testing
@testable import CmuxNextApp
@testable import CmuxNextTerminal

/// `appearance.backgroundOpacity` and `appearance.backgroundBlur` in
/// cmux.json override Ghostty's `background-opacity` and `background-blur`
/// in both places the window reads them: the resolved theme tokens
/// (`ThemeBridge`, then `WindowBackdrop(tokens)`) and the Ghostty config the
/// terminal surfaces get (whose opacity the surface policy reads).
struct WindowBackgroundOverrideTests {
    /// Ghostty colors for an opaque config with a blur radius.
    private static func ghostty(opacity: Double = 1, blur: Int = 20) -> GhosttyThemeColors {
        GhosttyThemeColors(background: .init(r: 0x1E, g: 0x1E, b: 0x2E), foreground: .init(r: 0xCD, g: 0xD6, b: 0xF4),
                           palette: [], selectionBackground: nil, selectionForeground: nil,
                           backgroundOpacity: opacity, backgroundBlur: blur)
    }

    private static func tokens(_ json: JSONValue, ghostty colors: GhosttyThemeColors = ghostty()) -> ThemeTokens {
        let snapshot = CmuxConfigSnapshot.parse(json, validDensities: [], validMetrics: [])
        return ThemeTokens.derive(from: ThemeBridge.input(colors, background: snapshot.windowBackground))
    }

    @Test func cmuxJSONOverridesGhosttysOpacityAndMaterial() {
        let tokens = Self.tokens(["appearance": ["backgroundOpacity": 0.6, "backgroundBlur": "glass-clear"]])
        #expect(tokens.backgroundOpacity == 0.6)
        #expect(WindowBackdrop(tokens).material == .glass(.clear))
        #expect(WindowBackdrop(tokens).tintOpacity == 0.6)

        let frosted = Self.tokens(["appearance": ["backgroundOpacity": 0.7]], ghostty: Self.ghostty(opacity: 1, blur: -1))
        #expect(frosted.backgroundOpacity == 0.7)
        #expect(WindowBackdrop(frosted).material == .glass(.regular), "the opacity alone keeps Ghostty's glass")

        let glass = Self.tokens(["appearance": ["backgroundBlur": "frosted"]], ghostty: Self.ghostty(opacity: 0.9, blur: 0))
        #expect(WindowBackdrop(glass).material == .frosted)
        #expect(glass.backgroundOpacity == 0.9)
    }

    /// Without either key the window is what Ghostty says: opaque for the
    /// default config. Users who never opted into translucency see no change.
    @Test func unsetKeysKeepGhosttysValues() {
        let opaque = Self.tokens(.object([:]))
        #expect(opaque.backgroundOpacity == 1)
        #expect(WindowBackdrop(opaque).material == .opaque)
        let translucent = Self.tokens(.object([:]), ghostty: Self.ghostty(opacity: 0.85, blur: 20))
        #expect(translucent.backgroundOpacity == 0.85)
        #expect(WindowBackdrop(translucent).material == .frosted)
        // background-blur = false stays plainly see-through, not frosted.
        let seeThrough = Self.tokens(.object([:]), ghostty: Self.ghostty(opacity: 0.85, blur: 0))
        #expect(WindowBackdrop(seeThrough).material == .translucent)
    }

    @Test func aMaterialAloneTurnsTranslucencyOn() {
        let tokens = Self.tokens(["appearance": ["backgroundBlur": "frosted"]])
        #expect(tokens.backgroundOpacity == WindowBackgroundOverride.defaultTranslucentOpacity)
        #expect(WindowBackdrop(tokens).material == .frosted)
    }

    /// `none` drops the blur and keeps the resolved opacity.
    @Test func noneIsPlainlySeeThrough() {
        let tokens = Self.tokens(["appearance": ["backgroundOpacity": 0.5, "backgroundBlur": "none"]],
                                 ghostty: Self.ghostty(opacity: 0.8, blur: -1))
        #expect(tokens.backgroundOpacity == 0.5)
        #expect(WindowBackdrop(tokens).material == .translucent)
        let ghosttys = Self.tokens(["appearance": ["backgroundBlur": "none"]], ghostty: Self.ghostty(opacity: 0.8, blur: 20))
        #expect(ghosttys.backgroundOpacity == 0.8)
        #expect(WindowBackdrop(ghosttys).material == .translucent)
        let opaque = Self.tokens(["appearance": ["backgroundBlur": "none"]])
        #expect(WindowBackdrop(opaque).material == .opaque, "none alone does not turn translucency on")
    }

    /// The terminal side: the same override becomes Ghostty config lines, so
    /// the surfaces' resolved opacity (and their transparent default
    /// background) matches the tokens.
    @Test func theGhosttyConfigGetsTheResolvedValues() {
        let override = WindowBackgroundOverride(opacity: 0.6, material: .glass)
        #expect(GhosttyRuntime.backgroundOverrideLines(override, configuredOpacity: 1, configuredBlur: 0)
            == ["background-opacity = 0.6", "background-blur = macos-glass-regular"])
        #expect(GhosttyRuntime.backgroundOverrideLines(WindowBackgroundOverride(material: .glassClear), configuredOpacity: 0.8, configuredBlur: 0)
            == ["background-blur = macos-glass-clear"])
        #expect(GhosttyRuntime.backgroundOverrideLines(WindowBackgroundOverride(material: .unblurred), configuredOpacity: 0.8, configuredBlur: 20)
            == ["background-blur = 0"])
        #expect(GhosttyRuntime.backgroundOverrideLines(WindowBackgroundOverride(material: .frosted), configuredOpacity: 0.8, configuredBlur: 0)
            == ["background-blur = \(WindowBackgroundOverride.defaultFrostedRadius)"])
        #expect(GhosttyRuntime.backgroundOverrideLines(WindowBackgroundOverride(), configuredOpacity: 0.8, configuredBlur: 20).isEmpty)
        #expect(GhosttyRuntime.backgroundOverrideLines(override, configuredOpacity: 0.6, configuredBlur: -1).isEmpty)
        #expect(GhosttyRuntimeSurfacePolicy.override(configuredOpacity: 0.6, opacityCells: false) == "background-opacity = 0")
    }
}
