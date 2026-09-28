import AppKit
import Testing
@testable import CmuxFoundation

/// The chrome font setting reads one string and has to land on a drawable
/// typeface for every shape that string can take, including the machine that
/// does not have the configured font.
@Suite struct CmuxChromeFontTests {
    private let nothingInstalled: (String) -> Bool = { _ in false }
    private func installed(_ families: String...) -> (String) -> Bool {
        let set = Set(families)
        return { set.contains($0) }
    }

    @Test func emptySettingMeansFollowTheTerminal() {
        #expect(CmuxChromeFontSource(settingValue: "") == .terminal)
        #expect(CmuxChromeFontSource(settingValue: "   ") == .terminal)
    }

    @Test func reservedWordsAreCaseAndWhitespaceInsensitive() {
        #expect(CmuxChromeFontSource(settingValue: "Terminal") == .terminal)
        #expect(CmuxChromeFontSource(settingValue: " SYSTEM ") == .system)
    }

    @Test func anyOtherValueNamesAFamily() {
        #expect(CmuxChromeFontSource(settingValue: " SF Mono ") == .explicit("SF Mono"))
        #expect(CmuxChromeFontSource(settingValue: "SF Mono").settingValue == "SF Mono")
    }

    @Test func systemSourceKeepsTheSystemFont() {
        let typeface = CmuxChromeTypeface.resolved(
            source: .system,
            terminalFamilies: ["Berkeley Mono"],
            isInstalled: installed("Berkeley Mono")
        )

        #expect(typeface == .system)
    }

    @Test func terminalSourceTakesTheFirstInstalledFamily() {
        let typeface = CmuxChromeTypeface.resolved(
            source: .terminal,
            terminalFamilies: ["Berkeley Mono", "JetBrains Mono"],
            isInstalled: installed("JetBrains Mono")
        )

        // Not merely the first `font-family` directive: the family the terminal
        // actually resolves, which is the first one this machine can draw.
        #expect(typeface == .family("JetBrains Mono"))
    }

    @Test func terminalSourceFallsBackToMonospaceWhenNoFamilyIsDrawable() {
        let typeface = CmuxChromeTypeface.resolved(
            source: .terminal,
            terminalFamilies: ["Berkeley Mono"],
            isInstalled: nothingInstalled
        )

        // The terminal's own fallback, so a machine missing the font still sees
        // chrome that matches its terminal.
        #expect(typeface == .monospacedSystem)
    }

    @Test func terminalSourceWithNoConfiguredFamilyFallsBackToMonospace() {
        let typeface = CmuxChromeTypeface.resolved(
            source: .terminal,
            terminalFamilies: [],
            isInstalled: installed("Berkeley Mono")
        )

        #expect(typeface == .monospacedSystem)
    }

    @Test func explicitFamilyFallsBackToTheSystemFontNotTheTerminalFont() {
        let typeface = CmuxChromeTypeface.resolved(
            source: .explicit("Berkeley Mono"),
            terminalFamilies: ["JetBrains Mono"],
            isInstalled: installed("JetBrains Mono")
        )

        // The user asked for a specific chrome font. Silently substituting the
        // terminal font would look like the setting was ignored.
        #expect(typeface == .system)
    }

    @Test func installedExplicitFamilyWins() {
        let typeface = CmuxChromeTypeface.resolved(
            source: .explicit("Berkeley Mono"),
            terminalFamilies: ["JetBrains Mono"],
            isInstalled: installed("Berkeley Mono", "JetBrains Mono")
        )

        #expect(typeface == .family("Berkeley Mono"))
    }

    @Test func fontsKeepTheSizeTheyWereAskedFor() {
        // The setting picks a family, never a point size, so the sizes that
        // carry global magnification and accessibility scaling pass through.
        for typeface in [CmuxChromeTypeface.system, .monospacedSystem, .family("Menlo")] {
            let font = typeface.appKitFont(size: 17, weight: .semibold)
            #expect(font.pointSize == 17)
        }
    }

    @Test func monospacedSystemTypefaceIsMonospaced() {
        let font = CmuxChromeTypeface.monospacedSystem.appKitFont(size: 13, weight: .regular)
        let proportional = CmuxChromeTypeface.system.appKitFont(size: 13, weight: .regular)

        #expect(font.fontName != proportional.fontName)
    }

    @Test func missingFamilyDrawsTheSystemFontRatherThanASubstitute() {
        let font = CmuxChromeTypeface.family("Definitely Not An Installed Family").appKitFont(
            size: 13,
            weight: .regular
        )

        #expect(font.fontName == NSFont.systemFont(ofSize: 13, weight: .regular).fontName)
    }

    /// Labels that asked for a monospaced design or monospaced digits are asking
    /// for a width, not a style: a proportional chrome family would let a count
    /// move as it changes and a column of branch names stop lining up.
    @Test func aProportionalFamilyDoesNotSatisfyAFixedWidthRequest() {
        let proportional = CmuxChromeTypeface.family("Helvetica")
        #expect(proportional.appKitFont(size: 12, weight: .regular).isFixedPitch == false)

        let allGlyphs = proportional.appKitFont(size: 12, weight: .regular, needs: .allGlyphs)
        #expect(
            allGlyphs.fontName == NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName
        )
        #expect(allGlyphs.pointSize == 12)

        let digits = proportional.appKitFont(size: 12, weight: .semibold, needs: .digits)
        #expect(
            digits.fontName == NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold).fontName
        )
    }

    @Test func aFixedPitchFamilyIsKeptForBothRequests() {
        let menlo = CmuxChromeTypeface.family("Menlo")
        let plain = menlo.appKitFont(size: 12, weight: .regular)

        for need in [CmuxChromeTypeface.FixedPitchNeed.digits, .allGlyphs] {
            #expect(menlo.appKitFont(size: 12, weight: .regular, needs: need).fontName == plain.fontName)
        }
    }

    /// The system typeface is the case the old hardcoded call sites covered, so
    /// asking for fixed digits there has to keep drawing what they drew.
    @Test func theSystemTypefaceStillGetsMonospacedDigits() {
        let digits = CmuxChromeTypeface.system.appKitFont(size: 10, weight: .semibold, needs: .digits)

        #expect(digits.fontName == NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold).fontName)
    }

    @Test func weightsMapAcrossTheTwoFrameworks() {
        #expect(CmuxChromeTypeface.appKitWeight(matching: .regular) == .regular)
        #expect(CmuxChromeTypeface.appKitWeight(matching: .semibold) == .semibold)
        #expect(CmuxChromeTypeface.appKitWeight(matching: .bold) == .bold)
    }

    @Test func installedFamilyCheckRejectsNamesNoMachineHas() {
        #expect(CmuxChromeTypeface.isFamilyInstalled("Menlo"))
        #expect(!CmuxChromeTypeface.isFamilyInstalled("Definitely Not An Installed Family"))
        #expect(!CmuxChromeTypeface.isFamilyInstalled("  "))
    }
}
