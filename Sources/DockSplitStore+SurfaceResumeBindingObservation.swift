import Foundation

extension DockSplitStore {
    func seedRestoredSurfaceResumeBinding(
        _ resumeBinding: SurfaceResumeBindingSnapshot?,
        managed managedResumeBinding: SurfaceResumeBindingSnapshot?,
        terminal: TerminalPanel
    ) {
        if let resumeBinding {
            if surfaceResumeBindingMutationAllowed(resumeBinding, panelId: terminal.id) {
                surfaceResumeBindingsByPanelId[terminal.id] = resumeBinding
                terminal.shellActivity.restoredProcessDetectedBinding = RestoredProcessDetectedBinding(binding: resumeBinding)
            }
        }
        if let managedResumeBinding {
            managedAgentResumeBindingsByPanelId[terminal.id] = managedResumeBinding
        }
    }

    func effectiveSessionResumeBinding(
        panelId: UUID,
        detected: SurfaceResumeBindingSnapshot?,
        downgradeStoredProcessDetectedResumeBindingWhenDetectionUnavailable: Bool,
        detectedIsAmbiguous: Bool
    ) -> SurfaceResumeBindingSnapshot? {
        let stored = surfaceResumeBindingsByPanelId[panelId]
        let terminal = panels[panelId] as? TerminalPanel
        terminal?.shellActivity.restoredProcessDetectedBinding?.observe(storedBinding: stored, detectedBinding: detected)
        if let stored,
           stored.hasCompleteManagedSessionIdentity,
           managedAgentResumeBindingsByPanelId[panelId] == nil {
            managedAgentResumeBindingsByPanelId[panelId] = stored
        }
        let effective: SurfaceResumeBindingSnapshot?
        if let stored, let detected {
            effective = stored.shouldYieldToDetectedSurfaceResumeBinding(detected) ? detected : stored
        } else if let detected {
            effective = detected
        } else if var stored,
                  stored.isProcessDetected,
                  downgradeStoredProcessDetectedResumeBindingWhenDetectionUnavailable {
            // Recovery cannot synchronously scan processes before its owner is
            // torn down. Retain the command for explicit recovery, but never
            // treat the unverified cached binding as safe to auto-run.
            stored.autoResume = false
            stored.approvalPolicy = .manual
            stored.approvalRecordId = nil
            effective = stored
        } else if stored?.isProcessDetected == true {
            effective = detectedIsAmbiguous
                ? stored?.disablingAutomaticResume()
                : (terminal?.shellActivity.restoredProcessDetectedBinding?.preserves(stored) == true ? stored : nil)
        } else {
            effective = stored
        }
        if let effective {
            guard surfaceResumeBindingMutationAllowed(effective, panelId: panelId) else {
                return stored
            }
            surfaceResumeBindingsByPanelId[panelId] = effective
        } else {
            guard surfaceResumeBindingRemovalAllowed(panelId: panelId) else {
                return stored
            }
            surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
        }
        return effective
    }

}
