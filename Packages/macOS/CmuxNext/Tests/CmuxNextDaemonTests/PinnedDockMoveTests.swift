import Foundation
import Testing
@testable import CmuxNextDaemon

/// Home's dock move (`pinned-dock-alone-v1`): `move-tab-to-column` with a pinned dock moves a
/// screen's only tab into a lone pinned column. The app sent the dock without its `pinned` flag, so
/// the daemon refused the move ("a pane's only tab cannot be split out of that pane"), Home was
/// never docked, and every tab beside Home's page stayed in Home: Leo 2026-10-19, "i cant drag
/// from chief's right side tabs to the left sidebar".
struct PinnedDockMoveRequestTests {
    private static let homeDock = DockSnapshot(edge: .left, mode: .docked, role: .agentChat, isPinned: true)

    private func dock(of request: MoveTabToColumnRequest) throws -> JSONValue? {
        let data = try WireCoding.encodeRequest(request, id: 1)
        guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return fields["dock"]
    }

    @Test func aPinnedDockMoveTellsTheDaemonTheDockIsPinned() throws {
        let request = MoveTabToColumnRequest(surface: 7, target: .pane(PaneID(rawValue: 3)), width: 0.5, dock: Self.homeDock)
        #expect(try dock(of: request) == .object([
            "edge": .string("left"), "mode": .string("docked"), "role": .string("agent_chat"), "pinned": .bool(true),
        ]))
    }

    /// An ordinary dock move sends what it always sent: an older daemon reads it as before.
    @Test func anUnpinnedDockMoveSendsNoPin() throws {
        let plain = DockSnapshot(edge: .right, mode: .overlay)
        let request = MoveTabToColumnRequest(surface: 7, target: .pane(PaneID(rawValue: 3)), dock: plain)
        #expect(try dock(of: request) == .object(["edge": .string("right"), "mode": .string("overlay")]))
    }
}

/// The same move against the pinned branch cmux-tui: the screen's only tab becomes a lone pinned dock.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct PinnedDockMoveLiveTests {
    @Test func aScreensOnlyTabBecomesALonePinnedDock() async throws {
        try await BranchDaemonHarness.with { h in
            #expect(await h.connection.identity?.supports(DaemonCapability.pinnedDockAlone.rawValue) == true)
            let only = try await h.workspaceWithTerminal("home-dock")
            let dock = DockSnapshot(edge: .left, mode: .docked, role: .agentChat, isPinned: true)
            _ = try await h.connection.moveTabToColumn(only.surface, target: .pane(only.pane), width: 0.5, dock: dock)
            let screen = try await h.tree().workspaces.flatMap(\.screens).first { $0.panes.contains { $0.tabs.contains { $0.surface == only.surface } } }
            let columns = try #require(screen).columns
            #expect(columns.count == 1)
            #expect(columns.first?.dock?.isPinned == true)
            #expect(columns.first?.dock?.edge == .left)
        }
    }
}
