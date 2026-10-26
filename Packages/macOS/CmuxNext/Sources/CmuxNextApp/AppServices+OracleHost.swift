#if DEBUG || CMUX_BENCH_HOOKS
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
            // The settings the controller applied (no file read) and Reduce Motion as the motion gates see it.
            OracleSettingsFacet { [weak self] in
                guard let applied = self?.settings?.applied else { return nil }
                return OracleSettingsFacet.Reading(effectiveSha256: applied.effectiveSha256, nonDefaultKeys: applied.nonDefaultKeys(),
                                                   motionEnabled: applied.motionCategories.enabled,
                                                   motionSpeed: applied.animationSpeed.timeScale, reduceMotion: Motion.reduceMotion)
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
