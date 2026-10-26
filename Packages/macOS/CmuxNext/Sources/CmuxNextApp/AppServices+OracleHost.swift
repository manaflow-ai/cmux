#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextBridge
import CmuxNextOracle

/// The app's oracle facet providers (p15-oracle.md section 3A), registered as `debug.oracle.*` in DEV and
/// bench builds only: a Release build compiles neither this conformance nor any provider in the list. The
/// facet tasks (p15-oracle-027, 033 to 044, 188, 215, 216) add theirs to the list; until then each facet
/// answers not-comparable with its task.
extension AppServices: OracleHost {
    func makeOracleFacets() -> OracleFacets {
        OracleFacets([
            // Every workspace each window shows, the focused one and the ones `sidebar.multiView` puts beside it.
            OracleLayoutFacet { [weak self] () throws(OracleFacetError) -> [OracleLayoutFacet.Shown] in
                guard let self else { throw OracleFacetError("the app services are gone") }
                return windows.controllers.flatMap(\.onScreenContents).map { content in
                    OracleLayoutFacet.Shown(workspace: content.workspace.resourceID?.rawValue ?? content.workspace.id, model: content.layoutModel)
                }
            },
        ])
    }
}
#endif
