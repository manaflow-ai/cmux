#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextOracle

/// The app's oracle facet providers (p15-oracle.md section 3A), registered as `debug.oracle.*` in DEV and
/// bench builds only: a Release build compiles neither this conformance nor any provider in the list. The
/// facet tasks (p15-oracle-027, 033 to 044, 188, 215, 216) add theirs to the list; until then each facet
/// answers not-comparable with its task.
extension AppServices: OracleHost {
    func makeOracleFacets() -> OracleFacets { OracleFacets([]) }
}
#endif
