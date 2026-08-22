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
                    magnificationPercent
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
            abandon: { [weak self] identity, snapshot in
                self?.abandonConfigurationSnapshot(
                    snapshot,
                    for: identity
                )
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
        didCommit()
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
                for: identity
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
                for: identity
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
                for: identity
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
        if snapshot.appliesNativeConfiguration,
           let config,
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
        guard snapshot.refreshesHostAppearance else {
            return
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
        for identity: ObjectIdentifier
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
        Self.initializationLogger.error(
            "Terminal font reconciliation rolled back after retry exhaustion surface=\(surface.id.uuidString, privacy: .public)"
        )
    }
}
