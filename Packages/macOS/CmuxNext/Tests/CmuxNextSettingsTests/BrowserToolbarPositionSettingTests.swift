import CmuxNextAppearance
import CmuxNextSettings
import Testing

/// `browser.toolbarPosition` (user, 2026-10-20: "move my OmniBar tabs to the bottom side"): the
/// omnibar row of browser and Markdown panes at the top unless set; "bottom" moves it under the page.
@MainActor struct BrowserToolbarPositionSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let browser: [String: JSONValue] = value.map { ["toolbarPosition": $0] } ?? [:]
        return CmuxConfigSnapshot.parse(.object(["browser": .object(browser)]), validDensities: [], validMetrics: [])
    }

    @Test func topByDefaultWithASettingsRow() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.browserToolbarPosition == .top)
        #expect(snapshot.diagnostics.isEmpty)
        let row = SettingsSchema.descriptor(for: ["browser", "toolbarPosition"])
        #expect(row != nil, "a Settings row, which also lists it in the command palette")
        #expect(SettingsSchema.agentSettableKeys.contains("browser.toolbarPosition"), "looks only, like tabs.barPosition")
    }

    @Test func bottomApplies() {
        let snapshot = Self.parse(.string("bottom"))
        #expect(snapshot.browserToolbarPosition == .bottom)
        let design = DesignSettings()
        SettingsApplier.applyPlacement(snapshot, to: design)
        #expect(design.browserToolbarPosition == .bottom)
    }

    @Test func aBadValueKeepsTopAndSaysSo() {
        for bad: JSONValue in [.string("left"), .number(1)] {
            let snapshot = Self.parse(bad)
            #expect(snapshot.browserToolbarPosition == .top)
            #expect(snapshot.diagnostics.contains { $0.path == "browser.toolbarPosition" })
        }
    }
}
