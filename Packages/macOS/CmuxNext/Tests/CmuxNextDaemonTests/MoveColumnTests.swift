import Foundation
import Testing
@testable import CmuxNextDaemon

/// `move-column` (`column-move-v1`): a whole viewport column, every pane in
/// it, trades places with its left or right neighbor in one daemon commit.
struct MoveColumnRequestTests {
    @Test func theRequestNamesAPaneOfTheColumnAndADirection() throws {
        let data = try WireCoding.encodeRequest(MoveColumnRequest(pane: PaneID(rawValue: 12), direction: .right), id: 5)
        let fields = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(fields == .object([
            "id": .number(5), "cmd": .string("move-column"), "pane": .number(12), "direction": .string("right"),
        ]))
    }

    /// A daemon without the capability never receives the command.
    @Test func theRequestNeedsTheColumnMoveCapability() {
        #expect(MoveColumnRequest.requiredCapability == "column-move-v1")
        #expect(DaemonCapability.columnMove.rawValue == "column-move-v1")
        #expect(DaemonCapability.optional.contains("column-move-v1"))
        #expect(throws: DaemonError.self) { try MoveColumnRequest.requireServed(by: nil) }
    }
}

/// The same command against the pinned branch cmux-tui.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct MoveColumnLiveTests {
    @Test func aColumnOfTwoPanesMovesRightAsOneColumn() async throws {
        try await BranchDaemonHarness.with { h in
            #expect(await h.connection.identity?.supports(DaemonCapability.columnMove.rawValue) == true)
            let first = try await h.workspaceWithTerminal("columns")
            _ = try await h.connection.split(first.pane, direction: .down)
            let right = try await h.connection.newColumn(rightOf: first.pane)
            let rightPane = try #require(try await h.pane(of: right.surface)?.id)

            let before = try #require(try await screen(of: first.pane, h)).columns
            #expect(before.count == 2)
            #expect(before[0].layout.paneIDs.count == 2)

            try await h.connection.moveColumn(of: first.pane, direction: .right)
            let after = try #require(try await screen(of: first.pane, h)).columns
            #expect(after.map(\.id) == [before[1].id, before[0].id])
            #expect(after[0].layout.paneIDs == [rightPane])
            #expect(after[1].layout.paneIDs == before[0].layout.paneIDs)
        }
    }

    private func screen(of pane: PaneID, _ h: BranchDaemonHarness) async throws -> ScreenSnapshot? {
        try await h.tree().workspaces.flatMap(\.screens).first { $0.panes.contains { $0.id == pane } }
    }
}
