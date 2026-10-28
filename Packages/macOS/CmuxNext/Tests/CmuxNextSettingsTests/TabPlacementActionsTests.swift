import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Testing

/// Every choice of `tabs.barPosition` and `tabs.newTabPosition` is one action (user 2026-10-27,
/// task rule: each option in Settings, Cmd-Shift-P, the CLI and MCP): a palette row with a CLI verb
/// (MCP follows the CLI), and running it saves the value (the default removes the key) and, for the
/// tab bar, moves every pane's bar at once.
@MainActor struct TabPlacementActionsTests {
    private final class Saves {
        var writes: [([String], JSONValue?)] = []
    }

    private static func bound() -> (ActionRegistry, DesignSettings, Saves) {
        let registry = ActionRegistry.standard(), design = DesignSettings(), saves = Saves()
        TabPlacementSetting.bindActions(into: registry, design: design) { path, value in
            saves.writes.append((path, value))
            return nil
        }
        return (registry, design, saves)
    }

    @Test(arguments: [
        ("tabs.barPosition.top", "settings tab-bar-top"),
        ("tabs.barPosition.bottom", "settings tab-bar-bottom"),
        ("tabs.barPosition.left", "settings tab-bar-left"),
        ("tabs.barPosition.right", "settings tab-bar-right"),
        ("tabs.newTabPosition.afterCurrent", "settings new-tabs-after-current"),
        ("tabs.newTabPosition.beforeCurrent", "settings new-tabs-before-current"),
        ("tabs.newTabPosition.start", "settings new-tabs-at-start"),
        ("tabs.newTabPosition.end", "settings new-tabs-at-end"),
    ])
    func eachChoiceIsAPaletteRowACLIVerbAndAnMCPTool(id: String, cli: String) throws {
        let descriptor = try #require(ActionRegistry.standard().descriptor(for: ActionID(rawValue: id)))
        #expect(descriptor.surfaces.contains(.palette))
        #expect(descriptor.cliName == cli)
        #expect(descriptor.surfacePlan.mcp?.isOffered == true)
    }

    @Test func newTabBeforeCurrentTabIsAnAction() throws {
        let descriptor = try #require(ActionRegistry.standard().descriptor(for: "newTab.beforeCurrent"))
        #expect(descriptor.title == "New Tab Before Current Tab")
        #expect(descriptor.surfaces.contains(.palette))
        #expect(descriptor.cliName == "tab new-before-current")
    }

    @Test(arguments: [TabBarPosition.bottom, .left, .right])
    func aTabBarActionSavesAndMovesTheBar(position: TabBarPosition) {
        let (registry, design, saves) = Self.bound()
        #expect(registry.perform(ActionID(rawValue: "tabs.barPosition.\(position.rawValue)")))
        #expect(design.tabBarPosition == position)
        #expect(saves.writes.count == 1)
        #expect(saves.writes.first?.0 == ["tabs", "barPosition"])
        #expect(saves.writes.first?.1 == .string(position.rawValue))
    }

    @Test func theTopActionRemovesTheKey() {
        let (registry, design, saves) = Self.bound()
        design.tabBarPosition = .left
        #expect(registry.perform("tabs.barPosition.top"))
        #expect(design.tabBarPosition == .top)
        #expect(saves.writes.first?.0 == ["tabs", "barPosition"])
        #expect(saves.writes.first?.1 == nil)
    }

    @Test(arguments: [NewTabPosition.beforeCurrent, .start, .end])
    func aNewTabPositionActionSavesTheValue(position: NewTabPosition) {
        let (registry, _, saves) = Self.bound()
        #expect(registry.perform(ActionID(rawValue: "tabs.newTabPosition.\(position.rawValue)")))
        #expect(saves.writes.first?.0 == ["tabs", "newTabPosition"])
        #expect(saves.writes.first?.1 == .string(position.rawValue))
    }

    @Test func theAfterCurrentActionRemovesTheKey() {
        let (registry, _, saves) = Self.bound()
        #expect(registry.perform("tabs.newTabPosition.afterCurrent"))
        #expect(saves.writes.first?.0 == ["tabs", "newTabPosition"])
        #expect(saves.writes.first?.1 == nil)
    }
}
