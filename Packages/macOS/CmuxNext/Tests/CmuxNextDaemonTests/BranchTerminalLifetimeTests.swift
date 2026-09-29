import Foundation
import Testing
@testable import CmuxNextDaemon

/// Terminal lifetime against the pinned branch cmux-tui: new placements name
/// their own terminal in the shell environment, a closed tab's terminal can
/// be shown again while it lives, and `keep` is settable.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the pinned branch cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)))
struct BranchTerminalLifetimeTests {
    /// Every placement starts its shell with `CMUX_SURFACE_ID` naming the
    /// terminal the reply returns, and the tab lands in the target pane.
    @Test func placementsNameTheirTerminalInTheShell() async throws {
        try await BranchDaemonHarness.with { h in
            let (key, pane, _) = try await h.workspaceWithTerminal("placement")
            let options = SpawnOptions(cwd: h.root.path, workspace: key)
            let spawned = [
                try await h.connection.newTab(in: pane, options: options),
                try await h.connection.split(pane, direction: .right, options: options),
                try await h.connection.newColumn(rightOf: pane, options: options),
                try await h.connection.newPaneInColumn(of: pane, options: options),
            ]
            let tab = try await h.connection.newTab(in: pane, options: options)
            #expect(try await h.pane(of: tab.surface)?.id == pane)
            for created in spawned + [tab] {
                let terminal = try #require(created.terminalID)
                #expect(try await h.tab(created.surface)?.terminalID == terminal)
                let output = try await h.run("printf 'S=[%s] W=[%s]\\n' \"$CMUX_SURFACE_ID\" \"$CMUX_WORKSPACE_ID\"",
                                             in: created.surface, until: "]\r\n")
                #expect(output.contains("S=[\(DaemonConnection.uuidForm(terminal.rawValue))]"), "\(output)")
                #expect(output.contains("W=[\(DaemonConnection.uuidForm(key.rawValue))]"), "\(output)")
            }
        }
    }

    /// Reopening a closed tab within the grace period shows the same live
    /// terminal (scrollback intact); once it ended, projection fails.
    @Test func closedTabsTerminalCanBeProjectedBack() async throws {
        try await BranchDaemonHarness.with { h in
            let (key, pane, _) = try await h.workspaceWithTerminal("reopen")
            let created = try await h.connection.newTab(in: pane, options: SpawnOptions(cwd: h.root.path, workspace: key))
            _ = try await h.run("echo reopen-$((40+2))", in: created.surface, until: "reopen-42")
            let before = try #require(try await h.tab(created.surface))
            let terminalResource = try #require(before.terminalResourceID)
            let tree = try await h.tree()
            let workspace = try #require(tree.workspaces.first { $0.key == key })
            let screen = try #require(workspace.screens.first { $0.panes.contains { $0.id == pane } })
            let paneSnapshot = try #require(screen.panes.first { $0.id == pane })
            let path = PaneResourcePath(workspace: try #require(workspace.resourceID), screen: try #require(screen.resourceID),
                                        pane: try #require(paneSnapshot.resourceID))
            try await h.connection.closeTab(created.surface)
            #expect(try await h.tab(created.surface) == nil)

            let projected = try await h.connection.projectTerminal(terminalResource, into: path, index: 1)
            let restored = try #require(try await h.tree().workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
                .first { $0.tabResourceID == projected.id })
            #expect(restored.terminalID == before.terminalID)
            #expect(try await h.pane(of: restored.surface)?.id == pane)
            let attachment = try await TerminalAttachment.attach(
                endpoint: h.endpoint, target: .init(surface: restored.surface, generation: h.identity.generation),
                size: CellSize(cols: 120, rows: 30), claimGeometry: true)
            var iterator = attachment.events.makeAsyncIterator()
            guard case .replay(let replay)? = await iterator.next() else {
                Issue.record("attach did not start with a replay")
                return
            }
            await attachment.detach()
            #expect(String(decoding: replay.data, as: UTF8.self).contains("reopen-42"))

            let terminal = try #require(before.terminalID)
            try await h.connection.closeTerminal(terminal)
            await #expect(throws: DaemonError.self) {
                try await h.connection.projectTerminal(terminalResource, into: path, index: 0)
            }
        }
    }

    /// A kept terminal survives `set-terminal-keep` round trips by surface.
    @Test func keepIsSettableBySurface() async throws {
        try await BranchDaemonHarness.with { h in
            let (_, pane, _) = try await h.workspaceWithTerminal("keep")
            let created = try await h.connection.newTab(in: pane, options: SpawnOptions(keep: true))
            let off = try await h.connection.setTerminalKeep(.surface(created.surface), keep: false)
            #expect(off.keep == false)
            #expect(off.terminalID == created.terminalID)
        }
    }
}
