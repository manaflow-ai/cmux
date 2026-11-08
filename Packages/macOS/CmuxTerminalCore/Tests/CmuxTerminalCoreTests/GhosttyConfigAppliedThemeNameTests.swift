import Foundation
import Testing
@testable import CmuxTerminalCore

/// Unit coverage for the per-appearance theme resolution that backs the host
/// layer background (the #6411 fix). Unlike
/// ``GhosttyConfig/resolveThemeName(from:preferredColorScheme:)`` it must never
/// cross-side fall back from one appearance to the other.
@Suite struct GhosttyConfigAppliedThemeNameTests {
    @Test func oneSidedLightThemeResolvesOnlyForLight() {
        #expect(
            GhosttyConfig.appliedThemeName(from: "light:GitHub Light Default", preferredColorScheme: .light)
                == "GitHub Light Default"
        )
        #expect(
            GhosttyConfig.appliedThemeName(from: "light:GitHub Light Default", preferredColorScheme: .dark)
                == nil
        )
    }

    @Test func oneSidedDarkThemeResolvesOnlyForDark() {
        #expect(
            GhosttyConfig.appliedThemeName(from: "dark:Catppuccin Mocha", preferredColorScheme: .dark)
                == "Catppuccin Mocha"
        )
        #expect(
            GhosttyConfig.appliedThemeName(from: "dark:Catppuccin Mocha", preferredColorScheme: .light)
                == nil
        )
    }

    @Test func bothSidedThemeResolvesEachSide() {
        #expect(
            GhosttyConfig.appliedThemeName(from: "light:Catppuccin Latte,dark:Catppuccin Mocha", preferredColorScheme: .light)
                == "Catppuccin Latte"
        )
        #expect(
            GhosttyConfig.appliedThemeName(from: "light:Catppuccin Latte,dark:Catppuccin Mocha", preferredColorScheme: .dark)
                == "Catppuccin Mocha"
        )
    }

    @Test func identicalPairFromCLIEncodingResolvesInBothSchemes() {
        // `cmux themes set --light X --dark X` writes `light:X,dark:X`; both
        // appearances must resolve X so the forced theme applies everywhere.
        let value = "light:GitHub Light Default,dark:GitHub Light Default"
        #expect(GhosttyConfig.appliedThemeName(from: value, preferredColorScheme: .light) == "GitHub Light Default")
        #expect(GhosttyConfig.appliedThemeName(from: value, preferredColorScheme: .dark) == "GitHub Light Default")
    }

    @Test func plainThemeAppliesInEveryScheme() {
        #expect(GhosttyConfig.appliedThemeName(from: "Catppuccin Mocha", preferredColorScheme: .light) == "Catppuccin Mocha")
        #expect(GhosttyConfig.appliedThemeName(from: "Catppuccin Mocha", preferredColorScheme: .dark) == "Catppuccin Mocha")
    }

    @Test func unconditionalBaseAppliesWhenSideUnspecified() {
        // An unconditional base is the documented fallback; the *opposite*
        // conditional side is not.
        #expect(GhosttyConfig.appliedThemeName(from: "Catppuccin Mocha,light:Catppuccin Latte", preferredColorScheme: .dark) == "Catppuccin Mocha")
    }
}
