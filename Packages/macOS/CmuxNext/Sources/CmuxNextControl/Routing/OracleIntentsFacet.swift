#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextDaemon
public import CmuxNextOracle

/// The oracle's `intents` facet (schemas/oracle/snapshot-v1.schema.json `intents`): the daemon
/// store's pending intents, each as its transaction (relabeled by the runner), case name and target's public id,
/// and three totals since launch that only grow: intents applied, intents the store rolled back because the
/// daemon refused their command (``IntentTotals``), and refused perform turns (``OracleActionTurns``). The runner
/// diffs the totals between two checkpoints, so invariant I3's "settled == before + refusal" is a rolledBack or
/// refused delta; `lastRefusal` names what was refused for that check. Chromium's tests read monotonic counters
/// the same way: `base::HistogramTester` reports the samples since it was created
/// (base/test/metrics/histogram_tester.h).
///
/// A main-actor facet that reads stored values only, so reading it changes no state and the turn recorder can
/// arm it for I3's turn checkpoints. No private text: a case name, never the payload (names, titles).
public struct OracleIntentsFacet: OracleFacetProvider {
    public var facet: OracleFacet { .intents }
    public let capture: OracleFacetCapture

    /// - Parameters:
    ///   - store: The app's daemon store: its intent log and ``DaemonStore/intentTotals``.
    ///   - turns: The action registry's perform-turn observer: its refused turns.
    @MainActor
    public init(store: DaemonStore, turns: OracleActionTurns) {
        capture = .mainActor { [weak store, weak turns] () throws(OracleFacetError) -> OracleValue in
            guard let store, let turns else { throw OracleFacetError("the daemon store or the turn observer is gone") }
            return Self.value(store: store, turns: turns)
        }
    }

    @MainActor
    static func value(store: DaemonStore, turns: OracleActionTurns) -> OracleValue {
        let totals = store.intentTotals
        return [
            "pending": .array(store.pendingIntents.map { entry -> OracleValue in
                [
                    "intent": .string(entry.transaction.rawValue),
                    "op": .string(entry.intent.caseName),
                    "target": target(of: entry.intent, in: store).map(OracleValue.string) ?? .null,
                ]
            }),
            "totals": [
                "applied": OracleValue(totals.applied),
                "rolledBack": OracleValue(totals.rolledBack),
                "refused": OracleValue(turns.refusedTurns),
            ],
            "lastRefusal": [
                "action": turns.lastRefusedAction.map(OracleValue.string) ?? .null,
                "intent": totals.lastRolledBack.map(OracleValue.string) ?? .null,
            ],
        ]
    }

    /// The public id (`ws_…`, `screen_…`, `pane_…`, `tab_…`, a group id) of the one object `intent` changes, as
    /// `snapshot.get` prints it; nil when it changes no one public object (a column's rows, several tabs) or the
    /// object has no public id yet.
    @MainActor
    static func target(of intent: Intent, in store: DaemonStore) -> String? {
        switch intent {
        case .moveTab(let surface, _, _), .renameTab(let surface, _), .setTabPinned(let surface, _),
             .bindAgentSession(let surface, _, _):
            store.tab(surface: surface)?.resourceID?.rawValue
        case .closeTabs(let surfaces):
            surfaces.count == 1 ? surfaces.first.flatMap { store.tab(surface: $0)?.resourceID?.rawValue } : nil
        case .renamePane(let pane, _), .createTab(let pane, _), .splitPane(let pane, _, _, _):
            store.pane(pane)?.resourceID?.rawValue
        case .renameScreen(let screen, _), .setScreenColor(let screen, _), .setScreenIcon(let screen, _),
             .setScreenPinned(let screen, _):
            store.screen(screen)?.resourceID?.rawValue
        case .renameWorkspace(let key, _), .moveWorkspace(let key, _), .setWorkspaceGroup(let key, _),
             .placeWorkspace(let key, _, _):
            store.workspace(key: key)?.resourceID?.rawValue
        case .createWorkspace(let provisional, _):
            store.workspace(key: provisional.key)?.resourceID?.rawValue
        case .setWorkspaceGroupCollapsed(let group, _):
            group.rawValue
        case .setTabGroupCollapsed(let group, _):
            group.rawValue
        case .setRowHeights:
            nil
        }
    }
}
#endif
