import CmuxControlSocket
import CmuxGit
import CmuxSidebarGit
import Foundation

extension TerminalController: ControlPerformanceContext {
    func controlPerformanceMetricsRead() -> JSONValue? {
        let git = GitMetadataService.runtimeMetricsSnapshot()
        let sidebarGit = SidebarGitMetadataService.runtimeMetricsSnapshot()
        return JSONValue(
            foundationObject: [
                "schema_version": 1,
                "process": ProcessPerformanceMetrics.shared.snapshot().foundationObject,
                "mobile_workspace": MobileWorkspaceObserverMetrics.shared.snapshot().foundationObject,
                "git": [
                    "schema_version": NSNumber(value: git.schemaVersion),
                    "enabled": git.enabled,
                    "raw_tracked_status_scan_count": NSNumber(value: git.rawTrackedStatusScanCount),
                    "tracked_status_cache_hit_count": NSNumber(value: git.trackedStatusCacheHitCount),
                    "tracked_status_in_flight_join_count": NSNumber(value: git.trackedStatusInFlightJoinCount),
                ],
                "sidebar_git": [
                    "schema_version": NSNumber(value: sidebarGit.schemaVersion),
                    "enabled": sidebarGit.enabled,
                    "snapshot_batch_apply_count": NSNumber(value: sidebarGit.snapshotBatchApplyCount),
                    "material_change_count": NSNumber(value: sidebarGit.materialChangeCount),
                    "pull_request_seed_count": NSNumber(value: sidebarGit.pullRequestSeedCount),
                    "pull_request_traversal_count": NSNumber(value: sidebarGit.pullRequestTraversalCount),
                    "stale_apply_count": NSNumber(value: sidebarGit.staleApplyCount),
                ],
            ]
        )
    }

    func controlPerformanceMetricsReset() -> JSONValue? {
        ProcessPerformanceMetrics.shared.reset(enable: true)
        MobileWorkspaceObserverMetrics.shared.reset(enable: true)
        GitMetadataService.resetRuntimeMetrics(enable: true)
        SidebarGitMetadataService.resetRuntimeMetrics(enable: true)
        return controlPerformanceMetricsRead()
    }

    func controlPerformanceMetricsStop() -> JSONValue? {
        ProcessPerformanceMetrics.shared.disable()
        MobileWorkspaceObserverMetrics.shared.disable()
        GitMetadataService.disableRuntimeMetrics()
        SidebarGitMetadataService.disableRuntimeMetrics()
        return controlPerformanceMetricsRead()
    }
}
