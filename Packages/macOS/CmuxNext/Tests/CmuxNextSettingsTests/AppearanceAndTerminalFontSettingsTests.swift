import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// The settings the Settings window gained for the things people change
/// first (plans/cmux-next/settings-ia.md): the app theme
/// (`appearance.theme`), the terminal font (`terminal.fontFamily`,
/// `terminal.fontSize`) and the interface size
/// (`appearance.metrics.chromeFontSize`). Each parses with a fallback and a
/// diagnostic for a bad value, and is a schema row in the right section.
@Suite struct AppearanceAndTerminalFontSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [InterfaceSizeSetting.metricName])
    }

    @Test func absentKeysKeepTheGhosttyConfigWithoutDiagnostics() throws {
        let snapshot = try parse("{}")
        #expect(snapshot.appTheme == nil)
        #expect(snapshot.terminalFontFamily == nil)
        #expect(snapshot.terminalFontSize == nil)
        #expect(snapshot.metrics[InterfaceSizeSetting.metricName] == nil)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func readsAThemeNameOrALightDarkPairAsWritten() throws {
        #expect(try parse(#"{"appearance": {"theme": "Nord"}}"#).appTheme == "Nord")
        let pair = try parse(#"{"appearance": {"theme": " light:Rose Pine Dawn,dark:Rose Pine "}}"#)
        #expect(pair.appTheme == "light:Rose Pine Dawn,dark:Rose Pine")
        #expect(pair.diagnostics.isEmpty)
        // An empty theme is the Ghostty config's, as onboarding's Skip leaves it.
        let empty = try parse(#"{"appearance": {"theme": ""}}"#)
        #expect(empty.appTheme == nil)
        #expect(empty.diagnostics.isEmpty)
    }

    @Test func aThemeThatCouldInjectAConfigLineIsRefused() throws {
        for text in [#"{"appearance": {"theme": "Nord\nfont-size = 40"}}"#, #"{"appearance": {"theme": "a=b"}}"#,
                     #"{"appearance": {"theme": 3}}"#, #"{"appearance": {"theme": "light:Nord,night:Nord"}}"#] {
            let snapshot = try parse(text)
            #expect(snapshot.appTheme == nil, "\(text)")
            #expect(snapshot.diagnostics.map(\.path) == ["appearance.theme"], "\(text)")
        }
    }

    @Test func readsTheTerminalFont() throws {
        let snapshot = try parse(#"{"terminal": {"fontFamily": " Berkeley Mono ", "fontSize": 14}}"#)
        #expect(snapshot.terminalFontFamily == "Berkeley Mono")
        #expect(snapshot.terminalFontSize == 14)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func badTerminalFontValuesKeepTheGhosttyConfigWithADiagnostic() throws {
        let cases: [(String, String)] = [
            (#"{"terminal": {"fontFamily": "Mono\"Evil"}}"#, "terminal.fontFamily"),
            (#"{"terminal": {"fontFamily": 12}}"#, "terminal.fontFamily"),
            (#"{"terminal": {"fontSize": 3}}"#, "terminal.fontSize"),
            (#"{"terminal": {"fontSize": 200}}"#, "terminal.fontSize"),
            (#"{"terminal": {"fontSize": "big"}}"#, "terminal.fontSize"),
        ]
        for (text, path) in cases {
            let snapshot = try parse(text)
            #expect(snapshot.terminalFontFamily == nil && snapshot.terminalFontSize == nil, "\(text)")
            #expect(snapshot.diagnostics.map(\.path) == [path], "\(text)")
        }
        let long = String(repeating: "M", count: TerminalFontSetting.maximumFamilyLength + 1)
        #expect(try parse(#"{"terminal": {"fontFamily": "\#(long)"}}"#).terminalFontFamily == nil)
    }

    @Test func interfaceSizeOutsideItsRangeIsClampedWithADiagnostic() throws {
        let inside = try parse(#"{"appearance": {"metrics": {"chromeFontSize": 14}}}"#)
        #expect(inside.metrics[InterfaceSizeSetting.metricName] == 14)
        #expect(inside.diagnostics.isEmpty)
        let outside = try parse(#"{"appearance": {"metrics": {"chromeFontSize": 30}}}"#)
        // The value still reaches the applier, which clamps it, as before.
        #expect(outside.metrics[InterfaceSizeSetting.metricName] == 30)
        #expect(outside.diagnostics.map(\.path) == ["appearance.metrics.chromeFontSize"])
    }

    @MainActor @Test func interfaceSizeMatchesTheDesignMetric() {
        #expect(InterfaceSizeSetting.metricName == MetricKey.chromeFontSize.rawValue)
        let range = DesignSettings.allowedRange(.chromeFontSize)
        #expect(InterfaceSizeSetting.range == Double(range.lowerBound)...Double(range.upperBound))
    }

    @Test func theNewKeysAreRowsInTheirSections() throws {
        let theme = try #require(SettingsSchema.descriptor(for: AppThemeSetting.configPath))
        #expect(theme.section == .appearance)
        #expect(theme.kind == .theme)
        // First on the Appearance page.
        #expect(SettingsSchema.settings(in: .appearance).first?.path == AppThemeSetting.configPath)
        let interface = try #require(SettingsSchema.descriptor(for: InterfaceSizeSetting.configPath))
        #expect(interface.section == .appearance)
        #expect(interface.group == SettingsSchema.descriptor(for: ["appearance", "density"])?.group)
        let family = try #require(SettingsSchema.descriptor(for: TerminalFontSetting.familyPath))
        let size = try #require(SettingsSchema.descriptor(for: TerminalFontSetting.sizePath))
        #expect(family.kind == .fontFamily)
        #expect(SettingsSchema.settings(in: .terminal).map(\.path) == [TerminalFontSetting.familyPath, TerminalFontSetting.sizePath])
        for descriptor in [theme, interface, family, size] {
            #expect(!descriptor.title.isEmpty)
            #expect(!descriptor.keywords.isEmpty, "\(descriptor.id) has no search keywords")
            #expect(descriptor.defaultValue == nil && descriptor.defaultLabel != nil, "\(descriptor.id) default")
        }
        for descriptor in [theme, interface, family] {
            #expect(descriptor.help?.isEmpty == false, "\(descriptor.id) has no help")
        }
    }

    @Test func theDescriptorsAcceptWhatTheParsersAccept() throws {
        let theme = try #require(SettingsSchema.descriptor(for: AppThemeSetting.configPath))
        #expect(theme.accepts("Catppuccin Mocha"))
        #expect(theme.accepts("light:Rose Pine Dawn,dark:Rose Pine"))
        #expect(!theme.accepts(""))
        #expect(!theme.accepts("a=b"))
        let family = try #require(SettingsSchema.descriptor(for: TerminalFontSetting.familyPath))
        #expect(family.accepts("SF Mono"))
        #expect(!family.accepts(""))
        #expect(!family.accepts("Mono#1"))
        let size = try #require(SettingsSchema.descriptor(for: TerminalFontSetting.sizePath))
        #expect(size.accepts(13))
        #expect(!size.accepts(200))
    }

    @MainActor @Test func resetAllKeepsTheThemeAndTerminalFontButResetsInterfaceSize() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-look-reset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"appearance": {"theme": "Nord", "metrics": {"chromeFontSize": 14}}, "terminal": {"fontFamily": "SF Mono", "fontSize": 15}}"#.utf8)
            .write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url)
        try await settings.resetAllSettings()
        let root = try JSONC.parse(String(contentsOf: url, encoding: .utf8))
        #expect(root.value(at: AppThemeSetting.configPath) == "Nord")
        #expect(root.value(at: TerminalFontSetting.familyPath) == "SF Mono")
        #expect(root.value(at: TerminalFontSetting.sizePath) == 15)
        #expect(root.value(at: InterfaceSizeSetting.configPath) == nil)
    }
}
