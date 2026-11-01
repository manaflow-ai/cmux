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

    /// The second refusal kind of the probe (16 of 20 lost presses): the Ctrl-` was pressed on Cmd-N's stand-in, and its
    /// target is read after the daemon's workspace took the stand-in over (the stand-in is gone from the store). It named
    /// nothing (`PendingPaneNotCreated`, shown as "the daemon refused the new tab", with no request sent): it must name
    /// the daemon's pane, while Cmd-N's intent is still in the log and after it left.
    @Test func aCreateOnCmdNsStandInReadAfterTheHandOverNamesTheDaemonsPane() async throws {
        for settled in [false, true] {
            let store = Self.store()
            let key = WorkspaceKey.generate()
            let workspace = ProvisionalWorkspace(key: key, name: "2", tab: Self.page())
            let cmdN = ClientTransactionID.generate()
            store.intend(.createWorkspace(provisional: workspace, index: nil), transaction: cmdN)
            let daemonPane = PaneID(rawValue: 11)
            store.apply(snapshot: DaemonTree(workspaceRevision: 2,
                                             workspaces: [Self.base, Self.daemonWorkspace(key, pane: daemonPane, surface: SurfaceID(rawValue: 12))]))
            if settled {
                store.noteSettledAtNextSnapshot(cmdN)
                store.apply(snapshot: DaemonTree(workspaceRevision: 3,
                                                 workspaces: [Self.base, Self.daemonWorkspace(key, pane: daemonPane, surface: SurfaceID(rawValue: 12))]))
                #expect(!store.pendingIntents.contains { if case .createWorkspace = $0.intent { true } else { false } }, "Cmd-N's intent did not leave the log")
            }
            #expect(store.panesByHandle[workspace.pane] == nil, "the stand-in still shows after the hand-over")
            // A window that still shows the stand-in for a frame: the Ctrl-` names it.
            let terminal = ProvisionalTab()
            store.intend(.createTab(pane: workspace.pane, provisional: terminal.terminal(TerminalID.generate(), cwd: nil)),
                         transaction: .generate())
            var target: PaneID?
            var failure: (any Error)?
            do { target = try await store.daemonTarget(workspace.pane) } catch { failure = error }
            #expect(failure == nil, "settled \(settled): the create on the handed-over stand-in failed: \(String(describing: failure))")
            #expect(target == daemonPane, "settled \(settled): named \(String(describing: target)), not the daemon's pane \(daemonPane)")
            #expect(store.panesByHandle[daemonPane]?.tabs.map(\.surface) == [SurfaceID(rawValue: 12), terminal.surface],
                    "settled \(settled): the Ctrl-` tab does not show after the page in the daemon's pane")
        }
    }

    /// Review note 1 (receipt 6547143059): the daemon's workspace has two panes by the time the create is sent (a split
    /// made there meanwhile, its new pane active). The create pressed on Cmd-N's stand-in goes to the pane that holds
    /// Cmd-N's first tab, the one the stand-in showed, not to the active pane; before and after Cmd-N's intent left.
    @Test func aCreateOnCmdNsStandInGoesToThePaneOfItsFirstTabNotTheActivePane() async throws {
        for settled in [false, true] {
            let store = Self.store()
            let key = WorkspaceKey.generate()
            let workspace = ProvisionalWorkspace(key: key, name: "2", tab: Self.page())
            let cmdN = ClientTransactionID.generate()
            store.intend(.createWorkspace(provisional: workspace, index: nil), transaction: cmdN)
            let first = PaneID(rawValue: 11), split = PaneID(rawValue: 13)
            let page = SurfaceID(rawValue: 12)
            let tree = WorkspaceSnapshot(
                id: WorkspaceHandle(rawValue: 9), key: key, name: "2",
                screens: [ScreenSnapshot(id: ScreenID(rawValue: 10), active: true, activePane: split,
                                         layout: .split(id: SplitID(rawValue: 20), resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(first), b: .leaf(split)),
                                         panes: [PaneSnapshot(id: first, tabs: [TabSnapshot(surface: page, kind: .conversation)]),
                                                 PaneSnapshot(id: split, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 14))])])])
            store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [Self.base, tree]))
            ProvisionalTab.created(cmdN, surface: page, in: store)
            if settled {
                store.noteSettledAtNextSnapshot(cmdN)
                store.apply(snapshot: DaemonTree(workspaceRevision: 3, workspaces: [Self.base, tree]))
            }
            let target = try await store.daemonTarget(workspace.pane)
            #expect(target == first, "settled \(settled): named \(target), not the pane of Cmd-N's first tab \(first)")
        }
    }

    @Test func aDaemonPaneIsItsOwnTarget() async throws {
        let store = Self.store()
        let target = try await store.daemonTarget(Self.pane)
        #expect(target == Self.pane)
    }
}
