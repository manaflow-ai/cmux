#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextBridge
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextOracle

/// The app's oracle facet providers (p15-oracle.md section 3A), registered as `debug.oracle.*` in DEV and
/// bench builds only: a Release build compiles neither this conformance nor any provider in the list. The
/// facet tasks (p15-oracle-027, 033 to 044, 188, 215, 216) add theirs to the list; until then each facet
/// answers not-comparable with its task. The router adds `topology` itself (OracleTopologyFacet).
extension AppServices: OracleHost {
    func makeOracleFacets() -> OracleFacets {
        OracleFacets([
            // The input check `debug.desync` runs and the window problems `debug.focus` reports, now.
            OracleInvariantsFacet { [weak self] in
                guard let self, let monitor = input.monitor, let result = monitor.check() else { return nil }
                return OracleInvariantsFacet.Reading(violations: result.violations.map(\.invariant.rawValue),
                                                     windowInvariants: WindowInvariants.problems(windows), checks: monitor.checks)
            },
            // Every workspace each window shows, the focused one and the ones `sidebar.multiView` puts beside it.
            OracleLayoutFacet { [weak self] () throws(OracleFacetError) -> [OracleLayoutFacet.Shown] in
                guard let self else { throw OracleFacetError("the app services are gone") }
                return windows.controllers.flatMap(\.onScreenContents).map { content in
                    OracleLayoutFacet.Shown(workspace: content.workspace.resourceID?.rawValue ?? content.workspace.id, model: content.layoutModel)
                }
            },
            OracleTabsFacet { [weak self] in self?.oracleTabPanes() ?? [] },
            // What Recently Closed lists, from the daemons' mirrored closed history. Each title is hashed after the
            // request's `paths` (the case root and home, as normalize.py gets them) are rewritten.
            OracleHistoryFacet { [weak self] () throws(OracleFacetError) -> [ClosedItem] in
                guard let self else { throw OracleFacetError("the app services are gone") }
                let closed = DaemonClosedHistory.entries(DaemonClosedHistory.allKinds, in: self)
                return TabSearchFactsBuilder.listed(closed) { ($0.item, $0.daemon.machineID) }.map(\.item)
            },
            // The Dock badge and each workspace's unread count, from this Mac's daemon store, and its Needs you:
            // the agent chats in it whose acpmux lane waits on the person, as the sidebar row and Priority view read it.
            OracleNotificationsFacet { [weak self] () throws(OracleFacetError) -> OracleNotificationsFacet.Reading? in
                guard let self else { throw OracleFacetError("the app services are gone") }
                return try OracleNotificationsFacet.Reading(store: daemon.store, homeUnread: home.unreadConversations.map(\.rawValue)) {
                    AgentLaneStore.shared.needsYou(in: $0, turns: .shared)
                }
            },
        ])
    }

    /// Every `debug.oracle.*` method over the app's one facet list, the router's topology (`snapshots`) and
    /// the app's one turn recorder, ``oracleTurns``, the registry's perform-turn observer. `AppControl`
    /// registers these.
    @MainActor
    func oracleControlMethods(snapshots: ControlSnapshotStore) -> [ControlMethod] {
        OracleControl.methods(host: self, snapshots: snapshots, turns: oracleTurns)
    }
}
#endif
