import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// `appearance.appTheme`: the app theme apart from the terminal theme. `followTerminal` (the
/// default), an empty or absent value follow the terminal theme; a theme name or a light/dark
/// pair names one; anything else is a diagnostic and follows the terminal theme.
@Suite struct ChromeThemeSettingTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func theDefaultAndEmptyValuesFollowTheTerminalTheme() throws {
        for text in [#"{}"#, #"{"appearance": {"appTheme": "followTerminal"}}"#, #"{"appearance": {"appTheme": " "}}"#] {
            let snapshot = try parse(text)
            #expect(snapshot.chromeTheme == nil)
            #expect(snapshot.diagnostics.isEmpty)
        }
    }

    @Test func aThemeOrAPairNamesTheAppTheme() throws {
        #expect(try parse(#"{"appearance": {"appTheme": "Nord"}}"#).chromeTheme == "Nord")
        let pair = try parse(#"{"appearance": {"appTheme": "light:Rose Pine Dawn,dark:Rose Pine"}}"#)
        #expect(pair.chromeTheme == "light:Rose Pine Dawn,dark:Rose Pine")
        #expect(pair.appTheme == nil, "the terminal theme is a separate key")
    }

    @Test func aBadValueIsADiagnostic() throws {
        let snapshot = try parse(#"{"appearance": {"appTheme": 3}}"#)
        #expect(snapshot.chromeTheme == nil)
        #expect(snapshot.diagnostics.map(\.path) == ["appearance.appTheme"])
    }

    @Test func theSchemaRowDefaultsToFollowTerminalAndAcceptsThemes() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ChromeThemeSetting().configPath))
        #expect(descriptor.defaultValue == .string(ChromeThemeSetting.followTerminal))
        #expect(descriptor.accepts(.string("followTerminal")))
        #expect(descriptor.accepts(.string("light:A,dark:B")))
        #expect(!descriptor.accepts(.number(1)))
        #expect(SettingsSchema.keptOnResetAll.contains(ChromeThemeSetting().configPath))
    }
}
