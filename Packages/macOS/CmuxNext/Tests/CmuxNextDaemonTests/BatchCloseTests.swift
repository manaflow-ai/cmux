import Foundation
import Testing
@testable import CmuxNextDaemon

/// `batch-close-v1` against the pinned branch cmux-tui: many tabs, and the
/// terminals they end, close in one daemon command.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct BatchCloseTests {
    @Test func closeTabsEndsTerminalsWithNoTabLeft() async throws {
        try await BranchDaemonHarness.with { h in
            #expect(await h.connection.supportsBatchClose)
            let first = try await h.workspaceWithTerminal("one")
            let second = try await h.workspaceWithTerminal("two")
            let other = try await h.workspaceWithTerminal("three")
            let result = try await h.connection.closeTabs([first.surface, second.surface], transaction: "close-two")
            #expect(Set(result.closed) == [first.surface, second.surface])
            #expect(result.terminals.count == 2)
            #expect(try await h.tab(first.surface) == nil)
            #expect(try await h.tab(second.surface) == nil)
            #expect(try await h.tab(other.surface) != nil, "an unlisted tab stays")
        }
    }

    @Test func closeWorkspaceWithEndTerminalsClosesItAndItsTerminals() async throws {
        try await BranchDaemonHarness.with { h in
            let doomed = try await h.workspaceWithTerminal("doomed")
            let kept = try await h.workspaceWithTerminal("kept")
            let result = try await h.connection.closeWorkspace(doomed.key, endTerminals: true)
            #expect(result.key == doomed.key)
            let tree = try await h.tree()
            #expect(!tree.workspaces.contains { $0.key == doomed.key })
            #expect(tree.workspaces.contains { $0.key == kept.key })
            // The ended terminal cannot be closed again as a live terminal:
            // a second close-tabs on the old surface is refused.
            await #expect(throws: (any Error).self) { _ = try await h.connection.closeTabs([doomed.surface]) }
        }
    }
}
