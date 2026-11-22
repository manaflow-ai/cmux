import CmuxNextDesign
import CmuxNextSettings
import Testing

/// The window has no title strip by default (user, 2026-11-04: "we have a header now; we should
/// not have a header"); `window.titlebar` "standard" is an explicit opt-in. `tabs.barPosition`
/// bottom keeps the `window.titlebar` the user chose (user, 2026-10-28: "when tabbar is at bottom
/// we shouldnt show this at top (we need to conserve more space)").
@MainActor struct TabBarBottomTitlebarSettingTests {
    static func parse(_ object: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(object), validDensities: [], validMetrics: [])
    }

    @Test func theWindowStartsWithNoTitleStrip() throws {
        #expect(DesignSettings().titlebar == .minimal)
        #expect(Self.parse([:]).titlebar == .minimal)
        let row = try #require(SettingsSchema.descriptor(for: WindowTitlebarSetting.configPath))
        #expect(row.defaultValue == .string("minimal"))
    }

    @Test func anInvalidTitlebarKeepsTheMinimalDefault() {
        let snapshot = Self.parse(["window": .object(["titlebar": .string("unknown")])])
        #expect(snapshot.titlebar == .minimal)
        #expect(snapshot.diagnostics.contains { $0.path == "window.titlebar" })
    }

    @Test func bottomTabBarsKeepTheMinimalTitlebar() {
        let snapshot = Self.parse(["tabs": .object(["barPosition": .string("bottom")])])
        #expect(snapshot.tabBarPosition == .bottom)
        #expect(ChromePlacementSetting.effectiveTitlebar(snapshot) == .minimal, "no title strip above the panes")
    }

    @Test func bottomTabBarsKeepAStandardTitlebarTheUserChose() {
        let snapshot = Self.parse(["tabs": .object(["barPosition": .string("bottom")]),
                                   "window": .object(["titlebar": .string("standard")])])
        #expect(ChromePlacementSetting.effectiveTitlebar(snapshot) == .standard)
    }
}
