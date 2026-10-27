import CmuxNextBridge
import CmuxNextBridgeUI
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTabs
import Testing

/// A group the daemon colors with a custom `#RRGGBB` keeps that color in the app (cx-wqn5), as
/// workspace groups do: the screen bar's group maps to its own color, not the grey a token-only
/// mapping fell back to, while a token group still maps to its token.
@MainActor
struct TabGroupCustomColorTests {
    @Test func aHexGroupColorIsNotGrey() throws {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w")]))
        let workspace = try #require(store.workspaces.first)
        workspace.screenGroups = [
            ScreenGroupSnapshot(id: "custom", name: "Mine", color: "#AA5500"),
            ScreenGroupSnapshot(id: "token", name: "Red", color: "red"),
        ]
        let groups = ScreenBarMapping.shared.snapshot(workspace, untitled: { "Screen \($0)" }, emojiIcon: { _ in .none }).groups
        #expect(groups.count == 2)
        #expect(groups.first { $0.id == "custom" } != TabGroupItem(id: "custom", name: "Mine", colorToken: .grey))
        #expect(groups.first { $0.id == "custom" }?.tint.wire == GroupTint(wire: "#AA5500")?.wire)
        #expect(groups.first { $0.id == "token" } == TabGroupItem(id: "token", name: "Red", colorToken: .red))
    }

    /// A custom color picked in the group editor recolors the strip's group at once and goes to
    /// the daemon as `#RRGGBB`, the shape it stores (palette tokens still go out as tokens).
    @Test func aPickedCustomColorReachesTheStripAndTheDaemon() throws {
        let tint = try #require(GroupTint(wire: "#3366cc"))
        let strip = TabStripModel(tabs: [TabItem(id: "t", title: "t", groupID: "g")],
                                  groups: [TabGroupItem(id: "g", name: "API", colorToken: .blue)])
        #expect(strip.apply(.group(.setColor("g", tint)), makeTab: { TabItem(id: "n", title: "n") }))
        #expect(strip.group("g")?.tint == tint)
        #expect(TabGroupCommand.setColor("g", tint).arguments["color"] == "#3366CC")
        #expect(TabGroupCommand.setColor("g", .palette(.red)).arguments["color"] == "red")
    }
}
