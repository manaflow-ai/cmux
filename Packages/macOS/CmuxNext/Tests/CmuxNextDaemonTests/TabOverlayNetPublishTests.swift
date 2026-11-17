import Foundation
import Observation
import Testing
@testable import CmuxNextDaemon

/// While a tab creation waits for the daemon's answer (a held New Tab key makes one for each key), the intent overlay
/// takes its stand-in tab out of the pane's tab list before every daemon batch and puts it back after
/// (`withOverlayLifted`). Each round trip wrote the pane's `tabs` 2 times for each waiting creation, and each restore
/// made a new record of the stand-in tab. So each tracked reader of the pane's tab list (the pane's strip) mapped
/// again on each batch, also when the batch was about another workspace, and the work of one batch grew with the
/// count of the waiting creations. A batch publishes only its net change to a pane's tab list, one time.
@MainActor
struct TabOverlayNetPublishTests {
    static let count = 30
    /// The creations that wait in the shown pane: one for each key of a held New Tab key.
    static let waiting = 12

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

    /// The shown workspace's pane (workspace 0's).
    static let shownPane = PaneID(rawValue: 100)

    static func shown(_ store: DaemonStore) throws -> PaneModel {
        try #require(store.workspace(id: "k000")?.screens.first?.panes.first)
    }

    /// A daemon batch about workspace `index` alone: a terminal tab opens in its pane.
    static func tabOpened(in index: Int, sequence: UInt64) -> DaemonEventEnvelope {
        let base = UInt64(index + 1) * 100
        let surface = SurfaceID(rawValue: base + 10 + sequence)
        return DaemonEventEnvelope(sequence: sequence, event: .tabAdded(TabDelta(
            workspace: WorkspaceHandle(rawValue: UInt64(index + 1)), screen: ScreenID(rawValue: base), pane: PaneID(rawValue: base),
            surface: surface, index: 1, entity: TabSnapshot(surface: surface), clientTransactionID: nil)))
    }

    /// Counts each change of a pane's tab list that a tracked reader hears. A tracked reader hears one change for each
    /// time it reads: this one reads again in the change's own call, so it counts each write.
    @MainActor final class Writes {
        var tabs = 0

        func track(_ pane: PaneModel) {
            withObservationTracking { _ = pane.tabs } onChange: {
                MainActor.assumeIsolated {
                    self.tabs += 1
                    self.track(pane)
                }
            }
        }
    }

    /// Makes `waiting` creations in the shown pane, as a held New Tab key does. Returns the pane.
    static func withWaitingCreations(_ store: DaemonStore) throws -> PaneModel {
        for _ in 0..<waiting { store.intend(.createTab(pane: shownPane, provisional: page()), transaction: .generate()) }
        let pane = try shown(store)
        try #require(pane.tabs.count == 1 + waiting, "setup: the pane lists \(pane.tabs.count) tabs, want \(1 + waiting)")
        return pane
    }

    /// RED at the base: each batch about a background workspace wrote the shown pane's tab list 2 times for each
    /// waiting creation (the lift took each stand-in tab out, the restore put a new record of it back). GREEN: such
    /// a batch writes nothing to the shown pane's tab list, and each stand-in tab keeps its record.
    @Test func aBatchAboutABackgroundWorkspaceWritesNoTabListOfAPaneWhoseCreationsWait() throws {
        let store = Self.store()
        let pane = try Self.withWaitingCreations(store)
        let records = pane.tabs.map(ObjectIdentifier.init)
        let ids = pane.tabs.map(\.id)
        let writes = Writes()
        writes.track(pane)

        // One batch for each background workspace: none is about the shown pane.
        for index in 1..<Self.count { _ = store.apply(batch: [Self.tabOpened(in: index, sequence: UInt64(index))]) }

        #expect(writes.tabs == 0,
                "\(Self.count - 1) batches about background workspaces wrote the shown pane's tab list \(writes.tabs) times, with \(Self.waiting) creations that wait")
        // The visible state is the same: the same tabs in the same order, and the batches' tabs are in their own panes.
        #expect(pane.tabs.map(\.id) == ids)
        #expect(pane.tabs.map(ObjectIdentifier.init) == records, "a stand-in tab got a new record while its creation waited")
        #expect(store.workspace(id: "k007")?.screens.first?.panes.first?.tabs.count == 2)
        #expect(store.mirrorViolations.isEmpty, "\(store.mirrorViolations)")
    }

    /// What does change the pane's tab list still reaches its readers, one time, at the lift's end: the daemon adds a
    /// tab to the shown pane while the creations wait.
    @Test func aBatchThatAddsATabToThePaneWritesItsTabListOneTime() throws {
        let store = Self.store()
        let pane = try Self.withWaitingCreations(store)
        let writes = Writes()
        writes.track(pane)

        _ = store.apply(batch: [Self.tabOpened(in: 0, sequence: 1)])

        #expect(writes.tabs == 1, "one batch that adds one tab wrote the shown pane's tab list \(writes.tabs) times, want 1")
        #expect(pane.tabs.count == 2 + Self.waiting)
        #expect(pane.tabs.filter { !ProvisionalTab.isProvisional($0.id) }.count == 2)
        #expect(store.mirrorViolations.isEmpty, "\(store.mirrorViolations)")
    }

    /// With no creation that waits nothing is held: a batch that adds a tab to the pane writes its tab list as before.
    @Test func aPaneWithNoWaitingCreationPublishesEachWrite() throws {
        let store = Self.store()
        let pane = try Self.shown(store)
        let writes = Writes()
        writes.track(pane)

        _ = store.apply(batch: [Self.tabOpened(in: 0, sequence: 1)])

        #expect(writes.tabs == 1, "the batch wrote the pane's tab list \(writes.tabs) times, want 1")
        #expect(pane.tabs.count == 2)
        #expect(store.mirrorViolations.isEmpty, "\(store.mirrorViolations)")
    }
}
