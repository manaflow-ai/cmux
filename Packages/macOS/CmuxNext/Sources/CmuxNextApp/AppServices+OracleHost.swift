#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextBridge
import CmuxNextControl
import CmuxNextDesign
import CmuxNextOracle
import CmuxNextSettings

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
            OracleIntentsFacet(store: daemon.store, turns: oracleTurns),
            OracleTabsFacet { [weak self] in self?.oracleTabPanes() ?? [] },
            // The settings the controller applied (no file read) and the motion arm as the gates compute it from
            // the design settings the controller applied them to.
            OracleSettingsFacet { [weak self] in
                guard let settings = self?.settings else { return nil }
                let applied = settings.applied, motion = Motion.basePolicy(of: settings.design)
                return OracleSettingsFacet.Reading(effectiveSha256: applied.effectiveSha256, nonDefaultKeys: applied.nonDefaultKeys(),
                                                   motionEnabled: motion.animationsEnabled, motionSpeed: motion.speed.timeScale,
                                                   reduceMotion: motion.reduceMotion)
            },
        ])
    }

    /// Every `debug.oracle.*` method over the app's one facet list, the router's topology (`snapshots`) and the
    /// app's one turn recorder, ``oracleTurns`` (the registry's perform-turn observer); `AppControl` registers them.
    @MainActor
    func oracleControlMethods(snapshots: ControlSnapshotStore) -> [ControlMethod] {
        OracleControl.methods(host: self, snapshots: snapshots, turns: oracleTurns)
    }
}
#endif
