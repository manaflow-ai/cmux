import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `browser.showLoadingBar` (user, 2026-11-10: "by default we shouldn't show the loading bar under
/// the omnibar area (but user can turn it on)"): off unless set; true turns the line back on.
@MainActor struct BrowserLoadingBarSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let browser: [String: JSONValue] = value.map { ["showLoadingBar": $0] } ?? [:]
        return CmuxConfigSnapshot.parse(.object(["browser": .object(browser)]), validDensities: [], validMetrics: [])
    }

    @Test func offByDefaultWithASettingsRow() {
        let snapshot = Self.parse(nil)
        #expect(!snapshot.browserShowLoadingBar)
        #expect(snapshot.diagnostics.isEmpty)
        let design = DesignSettings()
        #expect(!design.browserShowsLoadingBar)
        let row = SettingsSchema.descriptor(for: ["browser", "showLoadingBar"])
        #expect(row != nil, "a Settings row (Browser > Toolbar), also in the command palette")
        #expect(SettingsSchema.agentSettableKeys.contains("browser.showLoadingBar"), "looks only")
    }

    @Test func trueTurnsTheLineOnAndBackOff() {
        let design = DesignSettings()
        SettingsApplier.applyPlacement(Self.parse(.bool(true)), to: design)
        #expect(design.browserShowsLoadingBar)
        SettingsApplier.applyPlacement(Self.parse(nil), to: design)
        #expect(!design.browserShowsLoadingBar, "removing the key hides it again")
    }

    @Test func aBadValueKeepsItOffAndSaysSo() {
        for bad: JSONValue in [.string("yes"), .number(1)] {
            let snapshot = Self.parse(bad)
            #expect(!snapshot.browserShowLoadingBar)
            #expect(snapshot.diagnostics.contains { $0.path == "browser.showLoadingBar" })
        }
    }
}
