import Foundation
import Testing
@testable import CmuxNextDaemon

/// P0 STATUS 2080: Cmd-N, then Ctrl-` at once. The Ctrl-` named Cmd-N's stand-in pane before the daemon's workspace
/// took it over, and `daemonTarget` refused it at once ("This pane is still opening; try again in a moment"): no
/// terminal, in 4 of 4 quick rounds. A create on a stand-in whose own create is still in flight waits for that create
/// (no timer: the store resumes it when its records change) and then names the daemon's pane; a create that failed
/// gives `PendingPaneNotCreated`, which the action shows as a refusal.
@MainActor
struct CmdNStandInTargetTests {
    private static let pane = PaneID(rawValue: 3)
    private static let baseKey = WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000001")
    private static let base = WorkspaceSnapshot(
        id: WorkspaceHandle(rawValue: 1), key: baseKey, name: "1",
        screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: pane, layout: .leaf(pane),
                                 panes: [PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 4))])])])

    private static func store() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [base]))
        return store
    }

    private static func page() -> TabSnapshot {
        ProvisionalTab().conversation(ConversationTabRef(agentSession: AgentSessionRef(host: "install:test", hostName: nil)))
    }

    /// The daemon's workspace for `key` with one pane `pane` holding the page's tab `surface`.
    private static func daemonWorkspace(_ key: WorkspaceKey, pane: PaneID, surface: SurfaceID) -> WorkspaceSnapshot {
        WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 9), key: key, name: "2",
                          screens: [ScreenSnapshot(id: ScreenID(rawValue: 10), active: true, activePane: pane, layout: .leaf(pane),
                                                   panes: [PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: surface, kind: .conversation)])])])
    }

    /// Records how `daemonTarget` ended, so the test can read it without awaiting it.
    @MainActor final class Outcome {
        var pane: PaneID?
        var error: (any Error)?
        var ended: Bool { pane != nil || error != nil }
    }

    @Test func aNewTerminalTabOnCmdNsStandInWaitsForTheDaemonsPaneAndNamesIt() async throws {
        let store = Self.store()
        let key = WorkspaceKey.generate()
        let workspace = ProvisionalWorkspace(key: key, name: "2", tab: Self.page())
        store.intend(.createWorkspace(provisional: workspace, index: nil), transaction: .generate())
        // Ctrl-` in the same turn: its stand-in tab shows in Cmd-N's stand-in pane at once.
        let terminal = ProvisionalTab()
        store.intend(.createTab(pane: workspace.pane, provisional: terminal.terminal(TerminalID.generate(), cwd: nil)),
                     transaction: .generate())
        #expect(store.panesByHandle[workspace.pane]?.tabs.map(\.surface).contains(terminal.surface) == true,
                "the Ctrl-` tab does not show in Cmd-N's stand-in pane in its turn")

        let outcome = Outcome()
        let send = Task { @MainActor in
            do { outcome.pane = try await store.daemonTarget(workspace.pane) } catch { outcome.error = error }
        }
        for _ in 0..<5 { await Task.yield() }
        #expect(outcome.error == nil, "the create on Cmd-N's stand-in was refused: \(String(describing: outcome.error))")
        #expect(outcome.pane == nil, "the create named a pane before the daemon had one: \(String(describing: outcome.pane))")

        // `create-workspace` answered with no screen yet: still nothing to name.
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [Self.base, WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 9), key: key, name: "2")]))
        for _ in 0..<5 { await Task.yield() }
        #expect(outcome.error == nil, "refused once the daemon's workspace had no pane yet: \(String(describing: outcome.error))")
        #expect(outcome.pane == nil, "named a pane before the daemon's workspace held one: \(String(describing: outcome.pane))")

        // The daemon's workspace holds its pane and the page: the create names that pane, never the stand-in.
        let daemonPane = PaneID(rawValue: 11)
        store.apply(snapshot: DaemonTree(workspaceRevision: 3,
                                         workspaces: [Self.base, Self.daemonWorkspace(key, pane: daemonPane, surface: SurfaceID(rawValue: 12))]))
        await send.value
        #expect(outcome.error == nil, "refused after the daemon took the stand-in over: \(String(describing: outcome.error))")
        #expect(outcome.pane == daemonPane, "named \(String(describing: outcome.pane)), not the daemon's pane \(daemonPane)")
        // The Ctrl-` tab still shows, now in the daemon's pane, after the page.
        #expect(store.panesByHandle[daemonPane]?.tabs.map(\.surface) == [SurfaceID(rawValue: 12), terminal.surface],
                "the Ctrl-` tab is not after the page in the daemon's pane: \(String(describing: store.panesByHandle[daemonPane]?.tabs.map(\.surface)))")
        #expect(store.mirrorViolations.isEmpty)
    }

    @Test func aCreateOnCmdNsStandInIsRefusedWhenCmdNFails() async throws {
        let store = Self.store()
        let key = WorkspaceKey.generate()
        let workspace = ProvisionalWorkspace(key: key, name: "2", tab: Self.page())
        let cmdN = ClientTransactionID.generate()
        store.intend(.createWorkspace(provisional: workspace, index: nil), transaction: cmdN)
        let outcome = Outcome()
        let send = Task { @MainActor in
            do { outcome.pane = try await store.daemonTarget(workspace.pane) } catch { outcome.error = error }
        }
        for _ in 0..<5 { await Task.yield() }
        #expect(!outcome.ended, "the create on Cmd-N's stand-in ended before Cmd-N did: \(String(describing: outcome.error))")
        // Cmd-N's create failed: the stand-in is gone, and the waiting create gets the refusal the person sees.
        store.rejectIntent(cmdN)
        await send.value
        #expect(outcome.pane == nil)
        #expect(outcome.error is PendingPaneNotCreated, "ended with \(String(describing: outcome.error)), not PendingPaneNotCreated")
    }

    @Test func aDaemonPaneIsItsOwnTarget() async throws {
        let store = Self.store()
        let target = try await store.daemonTarget(Self.pane)
        #expect(target == Self.pane)
    }
}
