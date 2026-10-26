@testable import CmuxNextDaemon
import CmuxNextCompat
import Observation
import Testing

/// The store's intent totals (p15-oracle-040, the oracle's `intents` facet): each intent counts once when it
/// leaves the log, as applied or rolled back; a refused command names its intent's case in `lastRolledBack`;
/// the totals only grow; an observer of them hears a rollback; the pending list carries each transaction.
/// Run: `swift test --filter IntentTotalsTests`.
@MainActor @Suite struct IntentTotalsTests {
    nonisolated private static let pane = PaneID(rawValue: 10)

    private static func store() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, name: "workspace-1", screens: [
                ScreenSnapshot(id: 100, name: "first", active: true, activePane: pane, layout: .leaf(pane),
                               panes: [PaneSnapshot(id: pane, name: "old", tabs: [TabSnapshot(surface: 1)])]),
            ]),
        ]))
        return store
    }

    @Test func aRefusedCommandCountsOneRollbackAndNamesItsCase() {
        let store = Self.store()
        let transaction = ClientTransactionID.generate()
        store.intend(.renamePane(pane: Self.pane, name: "secret name"), transaction: transaction)
        #expect(store.pendingIntents.map { $0.transaction } == [transaction])
        #expect(store.intentTotals == IntentTotals(), "an intent counts when it leaves, not when it shows")
        store.rejectIntent(transaction)
        #expect(store.intentTotals.rolledBack == 1)
        #expect(store.intentTotals.applied == 0)
        #expect(store.intentTotals.lastRolledBack == "renamePane", "the case name, never the payload")
        #expect(store.pendingIntents.isEmpty)
        // A late second rejection of the same transaction counts nothing.
        store.rejectIntent(transaction)
        #expect(store.intentTotals.rolledBack == 1)
    }

    @Test func aRepliedCommandCountsOneApplied() {
        let store = Self.store()
        let transaction = ClientTransactionID.generate()
        store.intend(.renamePane(pane: Self.pane, name: "logs"), transaction: transaction)
        store.noteSettled(transaction, at: store.appliedSequence)
        #expect(store.pendingIntents.isEmpty)
        #expect(store.intentTotals.applied == 1)
        #expect(store.intentTotals.rolledBack == 0)
        #expect(store.intentTotals.lastRolledBack == nil)
    }

    /// Ten intents, every third refused: the totals grow by one per intent that leaves and never go down.
    @Test func theTotalsOnlyGrow() {
        let store = Self.store()
        var previous = store.intentTotals
        for index in 0..<10 {
            let transaction = ClientTransactionID.generate()
            store.intend(.renamePane(pane: Self.pane, name: "n\(index)"), transaction: transaction)
            if index.isMultiple(of: 3) {
                store.rejectIntent(transaction)
            } else {
                store.noteSettled(transaction, at: store.appliedSequence)
            }
            let totals = store.intentTotals
            #expect(totals.applied >= previous.applied && totals.rolledBack >= previous.rolledBack)
            #expect(totals.applied + totals.rolledBack == previous.applied + previous.rolledBack + 1)
            previous = totals
        }
        #expect(previous.rolledBack == 4)
        #expect(previous.applied == 6)
    }

    /// `debug.oracle.wait_for` reads the facet under Observation tracking: a rollback must wake it.
    @Test func anObserverOfTheTotalsHearsARollback() {
        let store = Self.store()
        let transaction = ClientTransactionID.generate()
        store.intend(.renamePane(pane: Self.pane, name: "logs"), transaction: transaction)
        let heard = Heard()
        withObservationTracking { _ = store.intentTotals } onChange: { heard.set() }
        store.rejectIntent(transaction)
        #expect(heard.value)
    }
}

/// An observer's onChange ran (it may run on any thread).
private final class Heard: Sendable {
    private let heard = Mutex(false)
    nonisolated deinit {}
    var value: Bool { heard.withLock { $0 } }
    func set() { heard.withLock { $0 = true } }
}
