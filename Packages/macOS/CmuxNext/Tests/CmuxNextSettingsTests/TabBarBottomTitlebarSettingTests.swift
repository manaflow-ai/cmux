import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `tabs.barPosition` bottom keeps the `window.titlebar` the user chose. The
/// standard default restores the workspace-name strip; an explicit minimal
/// choice still conserves space (user, 2026-10-28: "when tabbar is at bottom
/// we shouldnt show this at top").
@MainActor struct TabBarBottomTitlebarSettingTests {
    static func parse(_ object: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(object), validDensities: [], validMetrics: [])
    }

    @Test func theWindowStartsWithTheStandardTitlebar() throws {
        #expect(DesignSettings().titlebar == .standard)
        #expect(Self.parse([:]).titlebar == .standard)
        let row = try #require(SettingsSchema.descriptor(for: WindowTitlebarSetting.configPath))
        #expect(row.defaultValue == .string("standard"))
    }

    @Test func anInvalidTitlebarKeepsTheStandardDefault() {
        let snapshot = Self.parse(["window": .object(["titlebar": .string("unknown")])])
        #expect(snapshot.titlebar == .standard)
        #expect(snapshot.diagnostics.contains { $0.path == "window.titlebar" })
    }

    @Test func bottomTabBarsUseTheStandardTitlebarByDefault() {
        let snapshot = Self.parse(["tabs": .object(["barPosition": .string("bottom")])])
        #expect(snapshot.tabBarPosition == .bottom)
        #expect(ChromePlacementSetting.effectiveTitlebar(snapshot) == .standard, "the standard title strip is the default")
    }

    @Test func bottomTabBarsKeepAnExplicitMinimalTitlebar() {
        let snapshot = Self.parse(["tabs": .object(["barPosition": .string("bottom")]),
                                   "window": .object(["titlebar": .string("minimal")])])
        #expect(ChromePlacementSetting.effectiveTitlebar(snapshot) == .minimal, "explicit minimal keeps the panes at the top")
    }
}
