import Foundation
import Testing
@testable import CmuxNextDaemon

/// Screen metadata, order and screen groups (`screen-metadata-v1`,
/// `screen-groups-v1`) against the pinned branch cmux-tui: the calls the
/// screen tab bar, palette and CLI make, and the tree and store they change.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct BranchScreenTests {
    @Test func screenColorIconPinOrderAndGroups() async throws {
        try await BranchDaemonHarness.with { h in
            let (key, _, _) = try await h.workspaceWithTerminal("screens")
            let handle = try #require(try await h.tree().workspaces.first { $0.key == key }?.id)
            let first = try #require(try await h.tree().workspaces.first { $0.key == key }?.screens.first?.id)
            let second = try #require(try await h.connection.newScreen(
                in: handle, spec: ScreenSpec(name: "logs", color: "green", icon: "🧪"),
                options: SpawnOptions(cwd: h.root.path)).screen)
            let third = try #require(try await h.connection.newScreen(
                in: handle, spec: ScreenSpec(name: "build"), options: SpawnOptions(cwd: h.root.path)).screen)

            try await h.connection.setScreenMetadata(first, color: .set("red"), icon: .set("terminal"))
            try await h.connection.setScreenPinned(third, true)
            try await h.connection.moveScreen(second, to: 1)
            var workspace = try #require(try await h.tree().workspaces.first { $0.key == key })
            #expect(workspace.screens.map(\.id) == [third, second, first], "pinned first, then the moved screen")
            let firstScreen = try #require(workspace.screens.first { $0.id == first })
            #expect(firstScreen.color == "red" && firstScreen.icon == "terminal")
            let secondScreen = try #require(workspace.screens.first { $0.id == second })
            #expect(secondScreen.name == "logs" && secondScreen.color == "green" && secondScreen.icon == "🧪")
            #expect(workspace.screens.first?.pinned == true)

            try await h.connection.setScreenMetadata(first, color: .clear, icon: .unchanged)
            let grouped = try await h.connection.createScreenGroup([second, first], name: "Checks", color: "blue")
            let group = try #require(grouped.groupID ?? grouped.group?.id)
            _ = try await h.connection.updateScreenGroup(group, collapsed: true)
            workspace = try #require(try await h.tree().workspaces.first { $0.key == key })
            let run = try #require(workspace.screenGroups.first { $0.id == group })
            #expect(run.name == "Checks" && run.collapsed && Set(run.screens) == [second, first])
            #expect(workspace.screens.first { $0.id == first }?.color == nil)
            #expect(workspace.screens.first { $0.id == first }?.icon == "terminal")

            _ = try await h.connection.saveScreenGroup(group)
            let saved = try await h.connection.listSavedScreenGroups()
            #expect(saved.contains { $0.name == "Checks" })

            try await h.store.waitUntil("store sees the collapsed screen group") {
                h.store.workspaces.first { $0.key == key }?.screenGroups.first { $0.id == group }?.collapsed == true
            }
            _ = try await h.connection.ungroupScreenGroup(group)
            workspace = try #require(try await h.tree().workspaces.first { $0.key == key })
            #expect(workspace.screenGroups.isEmpty)
            #expect(workspace.screens.allSatisfy { $0.group == nil })
        }
    }
}
