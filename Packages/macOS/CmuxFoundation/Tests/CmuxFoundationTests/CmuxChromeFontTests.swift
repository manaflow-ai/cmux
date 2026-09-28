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
        let typeface = CmuxChromeFont.resolvedTypeface(
            source: .system,
            terminalFamilies: ["Berkeley Mono"],
            isInstalled: installed("Berkeley Mono")
        )

        #expect(typeface == .system)
    }

    @Test func terminalSourceTakesTheFirstInstalledFamily() {
        let typeface = CmuxChromeFont.resolvedTypeface(
            source: .terminal,
            terminalFamilies: ["Berkeley Mono", "JetBrains Mono"],
            isInstalled: installed("JetBrains Mono")
        )

        // Not merely the first `font-family` directive: the family the terminal
        // actually resolves, which is the first one this machine can draw.
        #expect(typeface == .family("JetBrains Mono"))
    }

    @Test func terminalSourceFallsBackToMonospaceWhenNoFamilyIsDrawable() {
        let typeface = CmuxChromeFont.resolvedTypeface(
            source: .terminal,
            terminalFamilies: ["Berkeley Mono"],
            isInstalled: nothingInstalled
        )

        // The terminal's own fallback, so a machine missing the font still sees
        // chrome that matches its terminal.
        #expect(typeface == .monospacedSystem)
    }

    @Test func terminalSourceWithNoConfiguredFamilyFallsBackToMonospace() {
        let typeface = CmuxChromeFont.resolvedTypeface(
            source: .terminal,
            terminalFamilies: [],
            isInstalled: installed("Berkeley Mono")
        )

        #expect(typeface == .monospacedSystem)
    }

    @Test func explicitFamilyFallsBackToTheSystemFontNotTheTerminalFont() {
        let typeface = CmuxChromeFont.resolvedTypeface(
            source: .explicit("Berkeley Mono"),
            terminalFamilies: ["JetBrains Mono"],
            isInstalled: installed("JetBrains Mono")
        )

        // The user asked for a specific chrome font. Silently substituting the
        // terminal font would look like the setting was ignored.
        #expect(typeface == .system)
    }

    @Test func installedExplicitFamilyWins() {
        let typeface = CmuxChromeFont.resolvedTypeface(
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
            let font = CmuxChromeFont.appKitFont(typeface: typeface, size: 17, weight: .semibold)
            #expect(font.pointSize == 17)
        }
    }

    @Test func monospacedSystemTypefaceIsMonospaced() {
        let font = CmuxChromeFont.appKitFont(typeface: .monospacedSystem, size: 13, weight: .regular)
        let proportional = CmuxChromeFont.appKitFont(typeface: .system, size: 13, weight: .regular)

        #expect(font.fontName != proportional.fontName)
    }

    @Test func missingFamilyDrawsTheSystemFontRatherThanASubstitute() {
        let font = CmuxChromeFont.appKitFont(
            typeface: .family("Definitely Not An Installed Family"),
            size: 13,
            weight: .regular
        )

        #expect(font.fontName == NSFont.systemFont(ofSize: 13, weight: .regular).fontName)
    }

    @Test func weightsMapAcrossTheTwoFrameworks() {
        #expect(CmuxChromeFont.appKitWeight(matching: .regular) == .regular)
        #expect(CmuxChromeFont.appKitWeight(matching: .semibold) == .semibold)
        #expect(CmuxChromeFont.appKitWeight(matching: .bold) == .bold)
    }

    @Test func installedFamilyCheckRejectsNamesNoMachineHas() {
        #expect(CmuxChromeFont.isFamilyInstalled("Menlo"))
        #expect(!CmuxChromeFont.isFamilyInstalled("Definitely Not An Installed Family"))
        #expect(!CmuxChromeFont.isFamilyInstalled("  "))
    }
}
