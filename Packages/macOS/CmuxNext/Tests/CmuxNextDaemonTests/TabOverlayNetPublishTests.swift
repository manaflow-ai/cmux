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

    /// The list's own work (the unread count, the first tab) runs one time at the batch's end for a pane whose
    /// creations wait. Inside the batch a screen that sums its panes' unread counts can read the old count of such a
    /// pane. The row holds what a reader sees after the batch: the daemon's new first tab with an unread notification
    /// counts in the store's unread count, the stored count is the count from each tab, and the pane's first tab is
    /// the new one.
    @Test func aBatchThatAddsAnUnreadFirstTabToAPaneWhoseCreationsWaitCountsItAtItsEnd() throws {
        let store = Self.store()
        let pane = try Self.withWaitingCreations(store)
        try #require(store.unreadBadge() == 0, "setup: the store counts \(store.unreadBadge()) unread tabs before the batch")
        let surface = SurfaceID(rawValue: 150)
        let unread = TabSnapshot(surface: surface, notification: TabNotification(notification: NotificationID(rawValue: 7), unread: true))

        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .tabAdded(TabDelta(
            workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 100), pane: Self.shownPane, surface: surface, index: 0,
            entity: unread, clientTransactionID: nil)))])

        #expect(store.unreadBadge() == 1, "the store counts \(store.unreadBadge()) unread tabs after the batch, want 1")
        #expect(store.recountedUnreadTotals() == store.unreadTotals, "the stored unread count is not the count from each tab")
        #expect(pane.firstTab?.surface == surface, "the pane's first tab is not the daemon's new first tab")
        #expect(pane.tabs.count == 2 + Self.waiting)
        #expect(store.mirrorViolations.isEmpty, "\(store.mirrorViolations)")
    }

    /// The time of the store's work for a hold of the New Tab key whose answers come one by one after the keys
    /// (decision of 2026-11-17): a print with no bound, for 3 sizes of the hold. Each key is one creation that
    /// waits. Each answer is the daemon's `tab-added` event with the creation's transaction, then the reply's
    /// settlement. The times are of a Debug build with no daemon, no window and no reader of the tab list.
    ///
    /// The conditions are of the model only: each key adds one stand-in tab, and after the last answer the pane has
    /// no stand-in tab and one tab more for each key.
    @Test func aHoldWithHeldAnswersReportsTheTimeOfTheStoresApplies() throws {
        for keys in [10, 30, 93] { try Self.reportTheApplies(of: keys) }
    }

    static func milliseconds(since began: ContinuousClock.Instant) -> Double {
        let took = ContinuousClock.now - began
        return Double(took.components.seconds) * 1e3 + Double(took.components.attoseconds) / 1e15
    }

    static func reportTheApplies(of keys: Int) throws {
        let store = Self.store()
        let pane = try shown(store)
        var asks: [(transaction: ClientTransactionID, page: TabSnapshot)] = []
        let keysBegan = ContinuousClock.now
        for _ in 0..<keys {
            let ask = (transaction: ClientTransactionID.generate(), page: page())
            store.intend(.createTab(pane: shownPane, provisional: ask.page), transaction: ask.transaction)
            asks.append(ask)
        }
        let intends = milliseconds(since: keysBegan)
        try #require(pane.tabs.count == 1 + keys, "setup: the pane lists \(pane.tabs.count) tabs after \(keys) keys, want \(1 + keys)")

        var applies: [Double] = []
        var settles: [Double] = []
        for (index, ask) in asks.enumerated() {
            let sequence = UInt64(index + 1)
            let surface = SurfaceID(rawValue: 5_000 + sequence)
            var entity = TabSnapshot(surface: surface, kind: .conversation)
            entity.conversation = ask.page.conversation
            let added = TabDelta(workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 100), pane: shownPane,
                                 surface: surface, index: nil, entity: entity, clientTransactionID: ask.transaction)
            let applyBegan = ContinuousClock.now
            _ = store.apply(batch: [DaemonEventEnvelope(sequence: sequence, event: .tabAdded(added))])
            applies.append(milliseconds(since: applyBegan))
            let settleBegan = ContinuousClock.now
            store.noteSettled(ask.transaction, at: sequence)
            settles.append(milliseconds(since: settleBegan))
        }

        func text(_ value: Double) -> String { String(format: "%.2f", value) }
        let left = pane.tabs.filter { ProvisionalTab.isProvisional($0.id) }.count
        print("new tab hold in the store, \(count) workspaces, \(keys) keys with the answers held: the keys' intents took "
            + "\(text(intends)) ms in sum; the store's applies of the \(applies.count) answers' events took "
            + "\(text(applies.reduce(0, +))) ms in sum (the first \(text(applies.first ?? -1)) ms, the last "
            + "\(text(applies.last ?? -1)) ms); the \(settles.count) settlements of the replies took "
            + "\(text(settles.reduce(0, +))) ms in sum; stand-in tabs left: \(left); the pane lists \(pane.tabs.count) tabs "
            + "(a Debug build, no daemon, no window, no reader of the tab list)")
        #expect(left == 0 && pane.tabs.count == 1 + keys,
                "the model: \(left) stand-in tabs left and \(pane.tabs.count) tabs after \(keys) answers, want 0 and \(1 + keys)")
        #expect(store.mirrorViolations.isEmpty, "\(store.mirrorViolations)")
    }
}
