import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Testing

/// `sidebar.drawnMenus`: off by default (the system menu, today's app), a look a theme file may set,
/// and applied to the shared design settings the sidebar reads as a menu opens, so a save hot-swaps it.
@MainActor @Suite(.serialized) struct SidebarDrawnMenusSettingTests {
    private func snapshot(_ sidebar: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["sidebar": .object(sidebar)]), validDensities: [], validMetrics: [])
    }

    @Test func itIsAnOffToggle() throws {
        let row = try #require(SettingsSchema.all.first { $0.path == SidebarDrawnMenusSetting.configPath })
        #expect(row.kind == .toggle)
        #expect(!SidebarDrawnMenusSetting().value(in: .object([:])))
        #expect(SidebarDrawnMenusSetting().value(in: .object(["sidebar": .object(["drawnMenus": .bool(true)])])))
    }

    @Test func aThemeFileMaySetIt() {
        #expect(ThemeFileOverlay.lookKeys.contains("sidebar.drawnMenus"))
    }

    @Test func applyingTurnsItOnAndOffAgain() {
        let design = DesignSettings.shared
        let saved = design.sidebarDrawnMenus
        defer { design.sidebarDrawnMenus = saved }
        let applier = SettingsApplier(design: design, registry: ActionRegistry())
        _ = applier.apply(snapshot(["drawnMenus": .bool(true)]))
        #expect(design.sidebarDrawnMenus)
        _ = applier.apply(snapshot([:]))
        #expect(!design.sidebarDrawnMenus)
    }
}
