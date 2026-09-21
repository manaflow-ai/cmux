import Foundation

extension Workspace {
    func reconcileSurfaceResumeBindings(
        using surfaceResumeBindingIndex: SurfaceResumeBindingIndex,
        restorableAgentIndex: RestorableAgentSessionIndex? = nil
    ) {
        guard surfaceResumeBindingIndex.isAvailable else { return }
        for panelId in panels.keys {
            let initialStoredBinding = surfaceResumeBindingsByPanelId[panelId]
            let detectedBinding = surfaceResumeBindingIndex.binding(workspaceId: id, panelId: panelId)
            if surfaceResumeBindingIndex.hasAmbiguousPanel(panelId), detectedBinding == nil {
                // A missing panel-only winner is uncertainty, not proof that a
                // process-backed binding exited; preserve the existing binding.
                continue
            }

            var storedBinding = initialStoredBinding
            if detectedBinding != nil {
                storedBinding?.clearRestoredProcessDetectionObservation()
                if let storedBinding {
                    surfaceResumeBindingsByPanelId[panelId] = storedBinding
                }
            }
            if detectedBinding == nil,
               storedBinding?.preservesRestoredProcessDetection() == true {
                continue
            }

            if let detectedBinding, detectedBinding.isPlainSSHProcessDetectedBinding {
                // A fresh process observation is authoritative evidence that
                // the SSH child is still alive.  It also closes the restore
                // observation gap so later misses can be interpreted as an
                // actual exit rather than startup churn.
                observedPlainSSHPanelIds.insert(panelId)
                pendingPlainSSHRestorePanelIds.remove(panelId)
                plainSSHDetectionMissesByPanelId[panelId] = 0
            }

            guard let storedBinding else {
                if let detectedBinding, detectedBinding.isProcessDetected {
                    guard surfaceResumeBindingMutationAllowed(
                        detectedBinding,
                        panelId: panelId
                    ) else {
                        continue
                    }
                    surfaceResumeBindingsByPanelId[panelId] = detectedBinding
                }
                continue
            }
            guard let detectedBinding else {
                if storedBinding.isPlainSSHProcessDetectedBinding {
                    if pendingPlainSSHRestorePanelIds.contains(panelId) {
                        // The restored PTY may not have exec'd `ssh` yet. Keep
                        // the binding for a bounded restore observation gap;
                        // the shell activity transition below retires it if
                        // SSH never starts.
                        let restoreMisses = (plainSSHDetectionMissesByPanelId[panelId] ?? 0) + 1
                        plainSSHDetectionMissesByPanelId[panelId] = restoreMisses
                        if restoreMisses >= Self.plainSSHRestoreObservationMissLimit {
                            guard surfaceResumeBindingRemovalAllowed(panelId: panelId) else {
                                continue
                            }
                            surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
                            pendingPlainSSHRestorePanelIds.remove(panelId)
                            plainSSHDetectionMissesByPanelId.removeValue(forKey: panelId)
                        }
                        continue
                    }
                    let misses = (plainSSHDetectionMissesByPanelId[panelId] ?? 0) + 1
                    plainSSHDetectionMissesByPanelId[panelId] = misses
                    if misses >= 2 {
                        guard surfaceResumeBindingRemovalAllowed(panelId: panelId) else {
                            continue
                        }
                        surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
                        observedPlainSSHPanelIds.remove(panelId)
                        plainSSHDetectionMissesByPanelId.removeValue(forKey: panelId)
                    }
                    continue
                }
                if storedBinding.isProcessDetected {
                    guard surfaceResumeBindingRemovalAllowed(panelId: panelId) else {
                        continue
                    }
                    surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
                } else if isStaleAgentHookBinding(
                    storedBinding,
                    panelId: panelId,
                    restorableAgentIndex: restorableAgentIndex
                ) {
                    // Preserve explicit restore for the exited session, but
                    // prevent the stale binding from replaying automatically
                    // on the next relaunch (#8446).
                    retireAgentHookResumeBinding(panelId: panelId)
                }
                continue
            }
            if storedBinding.shouldYieldToDetectedSurfaceResumeBinding(detectedBinding) {
                guard surfaceResumeBindingMutationAllowed(
                    detectedBinding,
                    panelId: panelId
                ) else {
                    continue
                }
                invalidateRestoredAgentLifecycleIfBindingIsReplaced(
                    by: detectedBinding,
                    panelId: panelId
                )
                surfaceResumeBindingsByPanelId[panelId] = detectedBinding
            } else if storedBinding.isProcessDetected {
                guard surfaceResumeBindingRemovalAllowed(panelId: panelId) else {
                    continue
                }
                surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
                observedPlainSSHPanelIds.remove(panelId)
                pendingPlainSSHRestorePanelIds.remove(panelId)
                plainSSHDetectionMissesByPanelId.removeValue(forKey: panelId)
            }
        }
    }

    func effectiveSurfaceResumeBinding(
        panelId: UUID,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex?,
        downgradeStoredProcessDetectedResumeBindingWhenDetectionUnavailable: Bool = false
    ) -> SurfaceResumeBindingSnapshot? {
        let storedBinding = surfaceResumeBindingsByPanelId[panelId]
        guard let surfaceResumeBindingIndex else {
            guard var storedBinding,
                  storedBinding.isProcessDetected,
                  downgradeStoredProcessDetectedResumeBindingWhenDetectionUnavailable else {
                return storedBinding
            }
            // A windowless recovery freeze cannot synchronously verify process
            // detection after it releases this workspace graph. Preserve the
            // command for manual recovery without trusting it to auto-run.
            storedBinding.autoResume = false
            storedBinding.approvalPolicy = .manual
            storedBinding.approvalRecordId = nil
            surfaceResumeBindingsByPanelId[panelId] = storedBinding
            return storedBinding
        }

        let detectedBinding = surfaceResumeBindingIndex.binding(workspaceId: id, panelId: panelId)
        if surfaceResumeBindingIndex.hasAmbiguousPanel(panelId), detectedBinding == nil {
            // Keep an uncertain binding available for explicit manual resume,
            // but never carry process-detected auto-launch through ambiguity.
            return storedBinding?.disablingAutomaticResume()
        }
        guard let storedBinding else { return detectedBinding }
        guard let detectedBinding else {
            if storedBinding.preservesRestoredProcessDetection() {
                return storedBinding
            }
            if storedBinding.isPlainSSHProcessDetectedBinding {
                let misses = plainSSHDetectionMissesByPanelId[panelId] ?? 0
                if pendingPlainSSHRestorePanelIds.contains(panelId) || misses < 2 {
                    return storedBinding
                }
                return nil
            }
            return storedBinding.isProcessDetected ? nil : storedBinding
        }
        if storedBinding.shouldYieldToDetectedSurfaceResumeBinding(detectedBinding) { return detectedBinding }
        if storedBinding.isProcessDetected { return nil }
        return storedBinding
    }

}
