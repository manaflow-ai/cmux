import Foundation
import Observation
import Testing
@testable import CmuxNextDaemon

/// SIDEBAR SMOOTH 2, F1 (SIDEBAR ROWS STATUS 15571 cause c). While Cmd-N's create is pending, the intent overlay
/// takes its stand-in workspace out of `workspaces` before every daemon batch and puts it back after
/// (`withOverlayLifted`). Each round trip wrote the observed list twice and the stand-in's screens twice, so every
/// tracked reader of them (the sidebar's rows pass, window membership) was cancelled and ran again on each batch,
/// though nothing a person sees changed: 15.6 ms of cancels and 19.0 ms of willSet per Cmd-N at 200 rows (cmux21,
/// 120 Hz). CLAUDE.md: a burst coalesces to one model update. A batch publishes only its net change, once.
@MainActor
struct CreateOverlayNetPublishTests {
    static let count = 50

    /// Workspace `index`: one screen, one pane, one terminal tab.
    static func workspace(_ index: Int) -> WorkspaceSnapshot {
        let base = UInt64(index + 1) * 100
        let pane = PaneID(rawValue: base)
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: String(format: "k%03d", index)),
                                 name: "w\(index)",
                                 screens: [ScreenSnapshot(id: ScreenID(rawValue: base), active: true, activePane: pane, layout: .leaf(pane),
                                                          panes: [PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: SurfaceID(rawValue: base + 1))])])])
    }

    static func store() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: (0..<count).map(workspace)))
        return store
    }

    static func page() -> TabSnapshot {
        ProvisionalTab().conversation(ConversationTabRef(agentSession: AgentSessionRef(host: "install:test", hostName: nil)))
    }

    /// A daemon batch about workspace `index` alone: a terminal tab opens in its pane.
    static func tabOpened(in index: Int, sequence: UInt64) -> DaemonEventEnvelope {
        let base = UInt64(index + 1) * 100
        let surface = SurfaceID(rawValue: base + 10 + sequence)
        return DaemonEventEnvelope(sequence: sequence, event: .tabAdded(TabDelta(
            workspace: WorkspaceHandle(rawValue: UInt64(index + 1)), screen: ScreenID(rawValue: base), pane: PaneID(rawValue: base),
            surface: surface, index: 1, entity: TabSnapshot(surface: surface), clientTransactionID: nil)))
    }

    /// Counts the changes a tracked reader of the list and of the stand-in's screens hears.
    @MainActor final class Wakes {
        var list = 0
        var screens = 0
    }

    static func track(_ store: DaemonStore, _ workspace: WorkspaceModel, into wakes: Wakes) {
        withObservationTracking { _ = store.workspaces } onChange: { MainActor.assumeIsolated { wakes.list += 1 } }
        withObservationTracking { _ = workspace.screens } onChange: { MainActor.assumeIsolated { wakes.screens += 1 } }
    }

    /// RED at base: every batch wrote the list and the stand-in's screens (the lift took the stand-in out, the
    /// restore put it back). GREEN: a batch that changes neither publishes neither.
    @Test func aBatchAboutAnotherWorkspacePublishesNoListOrStandInChange() throws {
        let store = Self.store()
        let key = WorkspaceKey.generate(), tab = Self.page()
        store.intend(.createWorkspace(provisional: ProvisionalWorkspace(key: key, name: "new", tab: tab), index: 0), transaction: .generate())
        let shown = try #require(store.workspace(id: key.rawValue))
        let wakes = Wakes()
        Self.track(store, shown, into: wakes)

        for sequence in 1...3 { _ = store.apply(batch: [Self.tabOpened(in: 7, sequence: UInt64(sequence))]) }

        #expect(wakes.list == 0, "3 batches about another workspace woke the readers of the list (\(wakes.list))")
        #expect(wakes.screens == 0, "3 batches about another workspace woke the readers of the stand-in's screens (\(wakes.screens))")
        // The visible state is the same: the stand-in at its slot with its page, the batches' tabs in workspace 7.
        #expect(store.workspaces.first === shown && store.workspaces.count == Self.count + 1)
        #expect(shown.screens.flatMap(\.panes).flatMap(\.tabs).map(\.surface) == [tab.surface])
        #expect(store.workspace(id: "k007")?.screens.first?.panes.first?.tabs.count == 4)
        #expect(store.mirrorViolations.isEmpty, "\(store.mirrorViolations)")
    }

    /// What a batch does change still reaches the readers, in the same batch: the daemon's own workspace taking the
    /// stand-in over keeps the model (no list change), and a workspace the daemon adds joins the list.
    @Test func aBatchThatChangesTheListPublishesIt() throws {
        let store = Self.store()
        let key = WorkspaceKey.generate(), tab = Self.page()
        let transaction = ClientTransactionID.generate()
        store.intend(.createWorkspace(provisional: ProvisionalWorkspace(key: key, name: "new", tab: tab), index: 0), transaction: transaction)
        let shown = try #require(store.workspace(id: key.rawValue))

        // create-workspace answered: the daemon's workspace (no tab yet) takes the stand-in's model over in place.
        var wakes = Wakes()
        Self.track(store, shown, into: wakes)
        let created = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 900), key: key, name: "new")
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [created] + (0..<Self.count).map(Self.workspace)))
        #expect(store.workspace(id: key.rawValue) === shown && !shown.isProvisional)
        #expect(wakes.list == 0, "the daemon's workspace took the same model over: the list did not change")
        #expect(shown.screens.flatMap(\.panes).flatMap(\.tabs).map(\.surface) == [tab.surface], "no frame shows it empty")

        // Another client makes a workspace: it joins the list, and its readers hear it.
        wakes = Wakes()
        Self.track(store, shown, into: wakes)
        store.apply(snapshot: DaemonTree(workspaceRevision: 3, workspaces: [created] + (0...Self.count).map(Self.workspace)))
        #expect(wakes.list == 1, "a workspace joined: its readers heard it once (\(wakes.list))")
        #expect(store.workspaces.count == Self.count + 2 && store.workspaces.first === shown)
        #expect(store.mirrorViolations.isEmpty, "\(store.mirrorViolations)")
    }
}
