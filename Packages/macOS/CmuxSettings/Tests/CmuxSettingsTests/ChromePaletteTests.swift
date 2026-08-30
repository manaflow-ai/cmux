import Foundation
import Testing
@testable import CmuxSettings

@Suite("Chrome palette")
struct ChromePaletteTests {
    @Test(arguments: ChromeThemeID.allCases)
    func everyBuiltInThemeHasBothVariants(theme: ChromeThemeID) {
        for scheme in ChromeColorScheme.allCases {
            let palette = ChromePalette.builtIn(theme: theme, colorScheme: scheme)
            #expect(palette.theme == theme)
            #expect(palette.colorScheme == scheme)
            #expect(palette.tokens.count == ChromeToken.allCases.count)
            #expect(palette.tokens.keys.count == ChromeToken.allCases.count)
        }
    }

    @Test
    func appearanceModeSelectsExplicitAndSystemVariants() {
        let explicitLight = ChromePalette.resolve(
            theme: .catppuccin,
            appearanceMode: .light,
            effectiveSystemScheme: .dark
        )
        #expect(explicitLight.colorScheme == .light)

        let explicitDark = ChromePalette.resolve(
            theme: .catppuccin,
            appearanceMode: .dark,
            effectiveSystemScheme: .light
        )
        #expect(explicitDark.colorScheme == .dark)

        let systemDark = ChromePalette.resolve(
            theme: .catppuccin,
            appearanceMode: .system,
            effectiveSystemScheme: .dark
        )
        #expect(systemDark.colorScheme == .dark)
    }

    @Test
    func validOverrideChangesOnlyTheNamedToken() throws {
        let base = ChromePalette.builtIn(theme: .default, colorScheme: .light)
        let override = try #require(ChromeTokenOverrides(hexValues: ["accent": "#123456"]))
        let resolved = ChromePalette.resolve(
            theme: .default,
            colorScheme: .light,
            overrides: override
        )
        #expect(resolved[.accent].hex == "#123456")
        #expect(resolved[.surface].hex == base[.surface].hex)
        #expect(resolved[.textSecondary].hex == base[.textSecondary].hex)
    }

    @Test
    func tokenCustomizationPreservesUnchangedDefaultRoles() throws {
        let base = ChromePalette.builtIn(theme: .default, colorScheme: .dark)
        #expect(!base.isCustomized(.surface))
        #expect(!base.isCustomized(.accent))

        let overrides = try #require(ChromeTokenOverrides(hexValues: ["accent": "#123456"]))
        let customized = ChromePalette.resolve(
            theme: .default,
            colorScheme: .dark,
            overrides: overrides
        )
        #expect(customized.isCustomized(.accent))
        #expect(!customized.isCustomized(.surface))

        let themed = ChromePalette.builtIn(theme: .gruvbox, colorScheme: .dark)
        #expect(themed.isCustomized(.surface))
        #expect(themed.isCustomized(.accent))
    }

    @Test(arguments: [
        ["unknown": "#123456"],
        ["accent": "#12"],
        ["accent": "not-a-color"],
    ])
    func malformedOverridePayloadFailsClosed(values: [String: String]) {
        #expect(ChromeTokenOverrides(hexValues: values) == nil)
    }

    @Test
    func jsonOverrideDecodingRejectsMixedShapes() {
        #expect(ChromeTokenOverrides.decodeFromJSON(["accent": "#123456", "surface": 42]) == nil)
        #expect(ChromeTokenOverrides.decodeFromJSON(["accent": "#123456"])?.values.count == 1)
    }

    @Test
    func malformedThemeRawValueFallsBackThroughTheKeyDefault() {
        #expect(ChromeThemeID.decodeFromJSON("not-a-theme") == nil)
        #expect(SettingCatalog().chrome.theme.defaultValue == .default)
    }

    @Test(arguments: ChromeThemeID.allCases)
    func builtInTextAndStatusColorsMeetContrast(theme: ChromeThemeID) {
        for scheme in ChromeColorScheme.allCases {
            let palette = ChromePalette.builtIn(theme: theme, colorScheme: scheme)
            #expect(palette.textPrimary.contrastRatio(with: palette.surface) >= 4.5)
            #expect(palette.textSecondary.contrastRatio(with: palette.surface) >= 3.0)
            #expect(palette.textTertiary.contrastRatio(with: palette.surface) >= 3.0)
            #expect(palette.textOnSelected.contrastRatio(with: palette.surfaceSelected) >= 4.5)
            #expect(palette.textOnAccent.contrastRatio(with: palette.accent) >= 4.5)
            for token in [
                ChromeToken.agentIdle,
                .agentWorking,
                .agentSuccess,
                .agentWarning,
                .agentError,
            ] {
                #expect(palette[token].contrastRatio(with: palette.surface) >= 3.0)
            }
        }
    }

    @Test
    func unsafeTextOverridesFailClosedToReadableRoles() throws {
        let overrides = try #require(ChromeTokenOverrides(hexValues: [
            "textPrimary": "#FFFFFF",
            "textSecondary": "#FFFFFF",
            "textTertiary": "#FFFFFF",
            "surface": "#FFFFFF",
            "accent": "#FFFFFF",
            "surfaceSelected": "#FFFFFF",
            "agentSuccess": "#FFFFFF",
        ]))
        let palette = ChromePalette.resolve(
            theme: .default,
            colorScheme: .light,
            overrides: overrides
        )

        #expect(palette.textPrimary.contrastRatio(with: palette.surface) >= 4.5)
        #expect(palette.textSecondary.contrastRatio(with: palette.surface) >= 3.0)
        #expect(palette.textTertiary.contrastRatio(with: palette.surface) >= 3.0)
        #expect(palette.agentSuccess.contrastRatio(with: palette.surface) >= 3.0)
        #expect(palette.textOnAccent.contrastRatio(with: palette.accent) >= 4.5)
        #expect(palette.textOnSelected.contrastRatio(with: palette.surfaceSelected) >= 4.5)
    }

    @Test
    func transparentOverrideComposesAgainstItsSurface() throws {
        let overrides = try #require(ChromeTokenOverrides(hexValues: [
            "accent": "#12345680",
        ]))
        let palette = ChromePalette.resolve(
            theme: .default,
            colorScheme: .dark,
            overrides: overrides
        )
        #expect(palette.accent.hex == "#12345680")
        #expect(palette.textOnAccent.contrastRatio(with: palette.accent, underlying: palette.surface) >= 4.5)
    }

    @Test
    func transparentSurfaceUsesTheResolvedSchemeAsItsFinalBackground() throws {
        let overrides = try #require(ChromeTokenOverrides(hexValues: [
            "surface": "#FFFFFF00",
            "textPrimary": "#000000",
            "textSecondary": "#000000",
        ]))
        let palette = ChromePalette.resolve(
            theme: .default,
            colorScheme: .dark,
            overrides: overrides
        )

        #expect(palette.textPrimary.contrastRatio(
            with: palette.surface,
            underlying: .black
        ) >= 4.5)
        #expect(palette.textSecondary.contrastRatio(
            with: palette.surface,
            underlying: .black
        ) >= 3.0)
    }

    @Test
    func readableForegroundTracksCustomizedStatusFill() throws {
        let overrides = try #require(ChromeTokenOverrides(hexValues: [
            "textPrimary": "#FFFFFF",
            "surface": "#202020",
            "agentIdle": "#FFFFFF",
        ]))
        let palette = ChromePalette.resolve(
            theme: .default,
            colorScheme: .dark,
            overrides: overrides
        )

        let foreground = palette.readableForeground(for: palette.agentIdle)
        #expect(foreground.contrastRatio(
            with: palette.agentIdle,
            underlying: palette.surface
        ) >= 4.5)
        #expect(foreground == .black)
    }

    @Test
    func colorHexRoundTripsAndRejectsAmbiguousInput() throws {
        let opaque = try #require(ChromeColor(hex: "#0088ff"))
        #expect(opaque.hex == "#0088FF")
        let translucent = try #require(ChromeColor(hex: "12345680"))
        #expect(translucent.hex == "#12345680")
        #expect(ChromeColor(hex: "#abc") == nil)
        #expect(ChromeColor(hex: "#GGGGGG") == nil)
        #expect(ChromeColor(hex: "+12345") == nil)
        #expect(ChromeColor(hex: "１２３４５６") == nil)
    }

    @Test
    func catalogIncludesChromeJSONKeys() {
        let catalog = SettingCatalog()
        let ids = Set(catalog.all.map(\.id))
        #expect(ids.contains("chrome.theme"))
        #expect(ids.contains("chrome.overrides"))
        #expect(catalog.chrome.theme.path.components == ["chrome", "theme"])
    }
}
