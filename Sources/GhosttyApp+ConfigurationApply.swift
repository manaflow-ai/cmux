import CmuxTerminal
import CmuxTerminalCore
import Foundation
import os

extension GhosttyApp {
    @MainActor
    func publishConfigurationPresentationMetrics(
        magnificationPercent: Int
    ) {
        let previous =
            terminalConfigurationPresentationMetrics
        let next =
            TerminalConfigurationPresentationMetrics.capture(
                magnificationPercent:
                    magnificationPercent,
                usesHostLayerBackground:
                    usesHostLayerBackground
            )
        terminalConfigurationPresentationMetrics = next
        next.publishChanges(comparedTo: previous)
    }

    @MainActor
    func scheduleConfigurationApply(
        _ snapshot: TerminalConfigurationApplySnapshot,
        didCommit: @escaping @MainActor () -> Void,
        completion: @escaping @MainActor () -> Void
    ) {
        let traversal = Self.terminalSurfaceRegistry
            .makeIncrementalTraversal()
        let prioritizedLifecycleIDs = AppDelegate.shared?
            .prioritizedTerminalSurfaceLifecycleIDsForConfigurationApply()
            ?? []
        let completionBox =
            TerminalConfigurationApplyCompletion(completion)
#if DEBUG
        cmuxDebugLog(
            "reload.config.surfaceApply.begin source=\(snapshot.source) prioritized=\(prioritizedLifecycleIDs.count)"
        )
#endif
        // This is the public acknowledgement boundary: the validated Ghostty
        // app configuration is committed, while surface fanout intentionally
        // continues asynchronously so reload_config cannot reintroduce the
        // all-surfaces main-actor stall.
        didCommit()
        terminalConfigurationApplyScheduler.replacePendingWork(
            snapshot: snapshot,
            prioritizedIDs: prioritizedLifecycleIDs,
            nextID: {
                guard let visit = traversal.nextVisit() else {
                    return .exhausted
                }
                guard let surface = visit.surface as? TerminalSurface else {
                    return .skipped
                }
                return .id(surface.terminalLifecycleId)
            },
            apply: { [weak self] lifecycleID, snapshot in
                self?.applyConfigurationSnapshot(
                    snapshot,
                    to: lifecycleID
                ) ?? .complete
            },
            abandon: { [weak self] lifecycleID, snapshot, reason in
                switch reason {
                case .retryLimitReached:
                    self?.abandonConfigurationSnapshot(
                        snapshot,
                        for: lifecycleID,
                        reason: .retryLimitReached
                    )
                case .pendingWorkReplaced:
                    self?.abandonConfigurationSnapshot(
                        snapshot,
                        for: lifecycleID,
                        reason: .pendingWorkReplaced
                    )
                }
            },
            completion: {
#if DEBUG
                cmuxDebugLog(
                    "reload.config.surfaceApply.end source=\(snapshot.source)"
                )
#endif
                completionBox.finish()
            }
        )
    }

    @MainActor
    private func applyConfigurationSnapshot(
        _ snapshot: TerminalConfigurationApplySnapshot,
        to lifecycleID: UUID
    ) -> TerminalConfigurationApplyResult {
        guard let surface = Self.terminalSurfaceRegistry
                .surface(terminalLifecycleID: lifecycleID)
                as? TerminalSurface else {
            abandonConfigurationSnapshot(
                snapshot,
                for: lifecycleID,
                reason: .surfaceUnavailable
            )
            return .complete
        }

        let state: TerminalConfigurationSurfaceApplyState
        if let existing = snapshot.surfaceState(
            lifecycleID: lifecycleID
        ), existing.surface === surface {
            state = existing
        } else {
            abandonConfigurationSnapshot(
                snapshot,
                for: lifecycleID,
                reason: .surfaceReplaced
            )
            let fontReloadState = surface
                .captureFontSizeConfigurationReloadState(
                    magnificationPercent:
                        snapshot.previousMagnificationPercent,
                    targetConfiguredRuntimePoints:
                        snapshot.terminalFontConfiguration
                            .configuredRuntimePoints,
                    targetMagnificationPercent:
                        snapshot.terminalFontConfiguration
                            .magnificationPercent
                )
            state = TerminalConfigurationSurfaceApplyState(
                surface: surface,
                fontReloadState: fontReloadState
            )
            snapshot.recordSurfaceState(
                state,
                lifecycleID: lifecycleID
            )
        }

        if !state.didApplyConfigurationStage {
            applyNativeAndHostConfiguration(
                snapshot,
                to: surface
            )
            state.didApplyConfigurationStage = true
        }

        guard Self.terminalSurfaceRegistry.isCurrentSurface(
            id: surface.id,
            terminalLifecycleID: lifecycleID
        ) else {
            abandonConfigurationSnapshot(
                snapshot,
                for: lifecycleID,
                reason: .surfaceUnregistered
            )
            return .complete
        }
        let outcome = surface
            .reconcileFontSizeAfterConfigurationReload(
                from: state.fontReloadState,
                configuredRuntimePoints:
                    snapshot.terminalFontConfiguration
                        .configuredRuntimePoints,
                magnificationPercent:
                    snapshot.terminalFontConfiguration
                        .magnificationPercent
            )
        if outcome == .failed {
            Self.initializationLogger.error(
                "Terminal font reconciliation attempt failed after config reload surface=\(surface.id.uuidString, privacy: .public)"
            )
            return .retry
        }
        snapshot.removeSurfaceState(lifecycleID: lifecycleID)
        return .complete
    }

    @MainActor
    private func applyNativeAndHostConfiguration(
        _ snapshot: TerminalConfigurationApplySnapshot,
        to surface: TerminalSurface
    ) {
        if let config,
           let liveSurface = surface
            .liveSurfaceForGhosttyAccess(
                reason: "configReload.incrementalApply"
            ) {
            suppressGhosttyReloadActions {
                ghostty_surface_update_config(
                    liveSurface,
                    config
                )
            }
            surface.hostedView
                .reapplySurfaceColorSchemeAfterGhosttyConfigReload(
                    preferredColorScheme:
                        snapshot.preferredColorScheme
                )
        }
        surface.hostedView
            .refreshHostBackgroundAfterGhosttyConfigReload()
        surface.forceRefresh(
            reason:
                GhosttySurfaceConfigurationRefresh
                    .forceRefreshReason
        )
    }

    @MainActor
    private func abandonConfigurationSnapshot(
        _ snapshot: TerminalConfigurationApplySnapshot,
        for lifecycleID: UUID,
        reason: ConfigurationSnapshotAbandonReason
    ) {
        guard let state = snapshot.removeSurfaceState(
            lifecycleID: lifecycleID
        ), let surface = state.surface else {
            return
        }
        surface
            .abandonFontSizeConfigurationReloadReconciliation(
                from: state.fontReloadState,
                magnificationPercent:
                    snapshot.terminalFontConfiguration
                        .magnificationPercent
            )
        switch reason {
        case .retryLimitReached:
            Self.initializationLogger.error(
                "Terminal font reconciliation rolled back after retry exhaustion surface=\(surface.id.uuidString, privacy: .public)"
            )
        case .pendingWorkReplaced,
             .surfaceUnavailable,
             .surfaceReplaced,
             .surfaceUnregistered:
            Self.initializationLogger.debug(
                "Terminal font reconciliation rolled back during surface churn reason=\(reason.rawValue, privacy: .public) surface=\(surface.id.uuidString, privacy: .public)"
            )
        }
    }
}

private enum ConfigurationSnapshotAbandonReason: String {
    case retryLimitReached = "retry-limit-reached"
    case pendingWorkReplaced = "pending-work-replaced"
    case surfaceUnavailable = "surface-unavailable"
    case surfaceReplaced = "surface-replaced"
    case surfaceUnregistered = "surface-unregistered"
}
