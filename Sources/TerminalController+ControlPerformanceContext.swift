import CmuxControlSocket
import CmuxGit
import CmuxSidebarGit
import Foundation

extension TerminalController: ControlPerformanceContext {
    nonisolated func v2PerformanceMetricsExerciseGitPR(
        params: [String: Any]
    ) async -> V2CallResult {
        guard Set(params.keys) == ["concurrent_requests", "exercise_nonce"],
              let nonce = params["exercise_nonce"] as? String,
              nonce.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              let concurrentRequests = v2Int(params, "concurrent_requests"),
              (2...8).contains(concurrentRequests) else {
            return .err(
                code: "invalid_params",
                message: "exercise_nonce must be 64 lowercase hex and concurrent_requests must be 2...8",
                data: nil
            )
        }
        guard GitMetadataService.runtimeMetricsSnapshot().enabled,
              SidebarGitMetadataService.runtimeMetricsSnapshot().enabled else {
            return .err(
                code: "metrics_disabled",
                message: "Reset performance metrics before exercising Git and PR owners",
                data: nil
            )
        }

        do {
            let git = try await GitOwnerPerformanceExercise.run(
                requestCount: concurrentRequests
            )
            let sidebarGit = try await SidebarGitOwnerPerformanceExercise.run(
                requestCount: concurrentRequests
            )
            guard git.completedSnapshotCount == concurrentRequests,
                  git.allSnapshotsMatched,
                  git.allWaitersRegistered,
                  sidebarGit.singleFlightApplyCount == 1,
                  sidebarGit.staleApplyCountBeforeFollowUp == 0,
                  sidebarGit.staleFinalApplyCount == 1,
                  let staleFinalBranch = sidebarGit.staleFinalBranch,
                  staleFinalBranch == "feature/stale-b" else {
                return .err(
                    code: "exercise_failed",
                    message: "Git and PR owner exercise did not complete its production ownership paths",
                    data: nil
                )
            }
            return .ok([
                "schema_version": 1,
                "exercise_nonce": nonce,
                "request_count": concurrentRequests,
                "isolation": "temporary_git_repository_and_in_memory_pr_host",
                "git": [
                    "completed_snapshot_count": git.completedSnapshotCount,
                    "all_snapshots_matched": git.allSnapshotsMatched,
                    "all_waiters_registered": git.allWaitersRegistered,
                ],
                "sidebar_git": [
                    "single_flight_apply_count": sidebarGit.singleFlightApplyCount,
                    "stale_apply_count_before_follow_up": sidebarGit.staleApplyCountBeforeFollowUp,
                    "stale_final_apply_count": sidebarGit.staleFinalApplyCount,
                    "stale_final_branch": staleFinalBranch,
                ],
            ])
        } catch {
            return .err(
                code: "exercise_failed",
                message: "Git and PR owner exercise failed",
                data: nil
            )
        }
    }

    nonisolated func v2PerformanceMetricsExerciseProcess(
        params: [String: Any]
    ) async -> V2CallResult {
        guard Set(params.keys) == ["concurrent_requests", "exercise_nonce"],
              let nonce = params["exercise_nonce"] as? String,
              nonce.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              let concurrentRequests = v2Int(params, "concurrent_requests"),
              (2...8).contains(concurrentRequests) else {
            return .err(
                code: "invalid_params",
                message: "exercise_nonce must be 64 lowercase hex and concurrent_requests must be 2...8",
                data: nil
            )
        }
        let startingMetrics = ProcessPerformanceMetrics.shared.snapshot()
        guard startingMetrics.enabled, startingMetrics.measurementEpoch > 0 else {
            return .err(
                code: "metrics_disabled",
                message: "Reset performance metrics before exercising process owners",
                data: nil
            )
        }

        guard let process = await CmuxTopProcessSnapshotStore.shared.performanceMetricsExercise(
            requestCount: concurrentRequests
        ), let listenerProof = await PortScanner.shared.performanceMetricsExercise(
            pids: [Int(getpid())]
        ) else {
            return .err(
                code: "exercise_failed",
                message: "Process owner exercise did not complete its production capture path",
                data: nil
            )
        }
        let completedMetrics = ProcessPerformanceMetrics.shared.snapshot()
        guard process.processCount > 0,
              process.measurementEpoch == startingMetrics.measurementEpoch,
              completedMetrics.enabled,
              completedMetrics.measurementEpoch == process.measurementEpoch,
              let generationMetrics = completedMetrics.generations[process.generation],
              generationMetrics.started == 1,
              generationMetrics.completed == 1,
              generationMetrics.processCount == process.processCount else {
            return .err(
                code: "exercise_failed",
                message: "Process owner exercise did not match its measurement epoch and generation metrics",
                data: nil
            )
        }
        return .ok([
            "schema_version": 2,
            "exercise_nonce": nonce,
            "measurement_epoch": NSNumber(value: process.measurementEpoch),
            "capture_generation": NSNumber(value: process.generation),
            "request_count": concurrentRequests,
            "process_count": process.processCount,
            "process_shared_snapshot": process.sharedSnapshotIdentity,
            "primary_consumer": ProcessSnapshotConsumer.performanceExercisePrimary.rawValue,
            "secondary_consumer": ProcessSnapshotConsumer.performanceExerciseSecondary.rawValue,
            "process_backend": process.proof.backend.rawValue,
            "process_launches": max(0, process.proof.processLaunchCount),
            "listener_backend": listenerProof.proof.backend.rawValue,
            "listener_process_launches": max(0, listenerProof.proof.processLaunchCount),
            "listener_shared_result": listenerProof.sharedResult,
        ])
    }

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
                    "tracked_status_request_count": NSNumber(value: git.trackedStatusRequestCount),
                ],
                "sidebar_git": [
                    "schema_version": NSNumber(value: sidebarGit.schemaVersion),
                    "enabled": sidebarGit.enabled,
                    "snapshot_batch_apply_count": NSNumber(value: sidebarGit.snapshotBatchApplyCount),
                    "material_change_count": NSNumber(value: sidebarGit.materialChangeCount),
                    "pull_request_seed_count": NSNumber(value: sidebarGit.pullRequestSeedCount),
                    "pull_request_traversal_count": NSNumber(value: sidebarGit.pullRequestTraversalCount),
                    "stale_apply_count": NSNumber(value: sidebarGit.staleApplyCount),
                    "pull_request_refresh_request_count": NSNumber(value: sidebarGit.pullRequestRefreshRequestCount),
                    "task_started": NSNumber(value: sidebarGit.pullRequestTaskStartedCount),
                    "task_joined": NSNumber(value: sidebarGit.pullRequestTaskJoinedCount),
                    "repo_fetch": NSNumber(value: sidebarGit.pullRequestRepoFetchCount),
                    "stale_completion_rejected_off_main": NSNumber(value: sidebarGit.pullRequestStaleCompletionRejectedOffMainCount),
                    "main_actor_apply_entered": NSNumber(value: sidebarGit.pullRequestMainActorApplyEnteredCount),
                    "follow_up_started": NSNumber(value: sidebarGit.pullRequestFollowUpStartedCount),
                    "git_stale_completion_rejected_off_main": NSNumber(value: sidebarGit.gitStaleCompletionRejectedOffMainCount),
                    "git_main_actor_apply_entered": NSNumber(value: sidebarGit.gitMainActorApplyEnteredCount),
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
