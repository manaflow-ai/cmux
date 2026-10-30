import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `tabs.barPosition` bottom keeps the `window.titlebar` the user chose (user, 2026-10-28: "when
/// tabbar is at bottom we shouldnt show this at top (we need to conserve more space)"). It used to
/// force the standard title bar, a strip with the workspace name above the panes.
@MainActor struct TabBarBottomTitlebarSettingTests {
    static func parse(_ object: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(object), validDensities: [], validMetrics: [])
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
