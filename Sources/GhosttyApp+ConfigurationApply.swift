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
        let prioritizedIDs = AppDelegate.shared?
            .prioritizedTerminalSurfaceIdentitiesForConfigurationApply()
            ?? []
        let completionBox =
            TerminalConfigurationApplyCompletion(completion)
#if DEBUG
        cmuxDebugLog(
            "reload.config.surfaceApply.begin source=\(snapshot.source) prioritized=\(prioritizedIDs.count)"
        )
#endif
        didCommit()
        terminalConfigurationApplyScheduler.replacePendingWork(
            snapshot: snapshot,
            prioritizedIDs: prioritizedIDs,
            nextID: {
                traversal.nextVisit()?.identity
            },
            apply: { [weak self] identity, snapshot in
                self?.applyConfigurationSnapshot(
                    snapshot,
                    to: identity
                ) ?? .complete
            },
            abandon: { [weak self] identity, snapshot, reason in
                switch reason {
                case .retryLimitReached:
                    self?.abandonConfigurationSnapshot(
                        snapshot,
                        for: identity,
                        reason: .retryLimitReached
                    )
                case .pendingWorkReplaced:
                    self?.abandonConfigurationSnapshot(
                        snapshot,
                        for: identity,
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
        to identity: ObjectIdentifier
    ) -> TerminalConfigurationApplyResult {
        guard let surface = Self.terminalSurfaceRegistry
                .surface(identity: identity)
                as? TerminalSurface else {
            abandonConfigurationSnapshot(
                snapshot,
                for: identity,
                reason: .surfaceUnavailable
            )
            return .complete
        }

        let state: TerminalConfigurationSurfaceApplyState
        if let existing = snapshot.surfaceState(
            identity: identity
        ), existing.surface === surface {
            state = existing
        } else {
            abandonConfigurationSnapshot(
                snapshot,
                for: identity,
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
                identity: identity
            )
        }

        if !state.didApplyConfigurationStage {
            applyNativeAndHostConfiguration(
                snapshot,
                to: surface
            )
            state.didApplyConfigurationStage = true
        }

        guard Self.terminalSurfaceRegistry
                .isRegistered(surface) else {
            abandonConfigurationSnapshot(
                snapshot,
                for: identity,
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
        snapshot.removeSurfaceState(identity: identity)
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
        for identity: ObjectIdentifier,
        reason: ConfigurationSnapshotAbandonReason
    ) {
        guard let state = snapshot.removeSurfaceState(
            identity: identity
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
