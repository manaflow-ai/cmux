import Foundation
import Testing
@testable import CmuxNextDaemon

/// Screen metadata, order and screen groups (the protocol/2 state
/// resources) against the pinned branch cmux-tui: the calls the screen tab
/// bar, palette and CLI make, and the snapshot and store they change.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the pinned branch cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct BranchScreenTests {
    @Test func screenColorIconPinOrderAndGroups() async throws {
        try await BranchDaemonHarness.with { h in
            let (key, _, _) = try await h.workspaceWithTerminal("screens")
            func workspace() async throws -> WorkspaceSnapshot {
                try #require(try await h.connection.snapshot().tree.workspaces.first { $0.key == key })
            }
            let handle = try await workspace().id
            let first = try #require(try await workspace().screens.first?.id)
            let second = try #require(try await h.connection.newScreen(
                in: handle, spec: ScreenSpec(name: "logs", color: "green", icon: "🧪")).screen)
            let third = try #require(try await h.connection.newScreen(in: handle, spec: ScreenSpec(name: "build")).screen)
            func id(_ screen: ScreenID) async throws -> ResourceID {
                try #require(try await workspace().screens.first { $0.id == screen }?.resourceID)
            }

            try await h.connection.updateScreen(try await id(first), color: .set("red"), icon: .set("terminal"))
            try await h.connection.updateScreen(try await id(third), pinned: true)
            try await h.connection.moveScreen(try await id(second), to: 1)
            var current = try await workspace()
            #expect(current.screens.map(\.id) == [third, second, first], "pinned first, then the moved screen")
            let firstScreen = try #require(current.screens.first { $0.id == first })
            #expect(firstScreen.color == "red" && firstScreen.icon == "terminal")
            let secondScreen = try #require(current.screens.first { $0.id == second })
            #expect(secondScreen.name == "logs" && secondScreen.color == "green" && secondScreen.icon == "🧪")
            #expect(current.screens.first?.pinned == true)

            try await h.connection.updateScreen(try await id(first), color: .clear)
            let group = try await h.connection.createScreenGroup([try await id(second), try await id(first)], name: "Checks",
                                                                 color: "blue")
            try await h.connection.updateScreenGroup(group, collapsed: true)
            current = try await workspace()
            let run = try #require(current.screenGroups.first { $0.id == group })
            #expect(run.name == "Checks" && run.collapsed && Set(run.screens) == [second, first])
            #expect(current.screens.first { $0.id == first }?.color == nil)
            #expect(current.screens.first { $0.id == first }?.icon == "terminal")

            try await h.store.waitUntil("store sees the collapsed screen group") {
                h.store.workspaces.first { $0.key == key }?.screenGroups.first { $0.id == group }?.collapsed == true
            }
            try await h.connection.ungroupScreenGroup(group)
            current = try await workspace()
            #expect(current.screenGroups.isEmpty)
            #expect(current.screens.allSatisfy { $0.group == nil })
        }
    }
}
