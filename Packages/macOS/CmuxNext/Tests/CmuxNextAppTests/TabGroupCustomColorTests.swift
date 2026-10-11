import CmuxNextBridge
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
        #expect(groups.first { $0.id == "token" } == TabGroupItem(id: "token", name: "Red", colorToken: .red))
    }
}
