@testable import CmuxNextSettings
import Testing

/// `browser.links.*` (R123): Chrome's defaults when unset, each key parsed
/// on its own, a bad value is that key's default plus a diagnostic.
@Suite struct BrowserLinkClickSettingTests {
    private func parse(_ links: JSONValue) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(["browser": ["links": links]], validDensities: SettingsSchemaTests.densities, validMetrics: [])
    }

    @Test func unsetIsChrome() {
        let empty = CmuxConfigSnapshot.parse(.object([:]), validDensities: SettingsSchemaTests.densities, validMetrics: [])
        let setting = empty.browserLinkClicks
        #expect(setting.cmdClick == .backgroundTab)
        #expect(setting.cmdShiftClick == .foregroundTab)
        #expect(setting.shiftClick == .newWindow)
        #expect(setting.optionClick == .download)
        #expect(setting.middleClick == .backgroundTab)
        for name in ["cmdClick", "cmdShiftClick", "shiftClick", "optionClick", "middleClick"] {
            let descriptor = SettingsSchema.descriptor(for: ["browser", "links", name])
            let field = BrowserLinkClickSetting.keys.first(where: { $0.name == name })?.field
            #expect(descriptor != nil && field != nil, "\(name) has a Settings row")
            if let descriptor, let field {
                #expect(descriptor.defaultValue == .string(setting[keyPath: field].rawValue))
            }
        }
    }

    @Test func everyKeyParses() {
        let snapshot = parse(["cmdClick": "foregroundTab", "cmdShiftClick": "newWindow", "shiftClick": "currentTab",
                              "optionClick": "backgroundTab", "middleClick": "download"])
        #expect(snapshot.diagnostics.isEmpty)
        let setting = snapshot.browserLinkClicks
        #expect(setting.cmdClick == .foregroundTab)
        #expect(setting.cmdShiftClick == .newWindow)
        #expect(setting.shiftClick == .currentTab)
        #expect(setting.optionClick == .backgroundTab)
        #expect(setting.middleClick == .download)
    }

    @Test func badValuesKeepTheirDefaultWithADiagnostic() {
        let snapshot = parse(["cmdClick": "sideways", "shiftClick": "currentTab"])
        #expect(snapshot.browserLinkClicks.cmdClick == .backgroundTab)
        #expect(snapshot.browserLinkClicks.shiftClick == .currentTab)
        #expect(snapshot.diagnostics.map(\.path) == ["browser.links.cmdClick"])
        #expect(parse("tabs").diagnostics.map(\.path) == ["browser.links"])
    }
}
