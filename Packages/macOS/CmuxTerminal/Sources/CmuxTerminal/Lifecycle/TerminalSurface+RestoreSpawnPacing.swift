extension TerminalSurface {
    @MainActor
    func shouldPaceRuntimeSurfaceCreation(source: RuntimeSurfaceCreationSource) -> Bool {
        guard requiresRestoreSpawnPacing else { return false }
        // Explicit input and scheduler-admitted restores retain their
        // existing immediate paths. A normal restore callback is queued; if
        // geometry re-enters while the admitted call is in Ghostty, the
        // in-progress guard drops the duplicate native attempt.
        guard source == .normal else { return false }
        guard surface == nil else { return false }
        return true
    }

    /// Whether this restored spawn runs the agent resume command its owner admitted.
    ///
    /// A cancelled admission also reaches `.admitted`, but suppresses the
    /// staged input and starts a plain shell.
    var restoredSpawnResumesAgent: Bool {
        startupRestoreAdmissionPhase == .admitted && !suppressConfiguredInitialInput
    }

    @MainActor
    func enqueueRestoredRuntimeSurfaceCreation(for view: any TerminalSurfaceNativeViewing) {
        guard !restoredRuntimeSurfaceStartQueued else { return }
        // A restored model can be attached to cmux's hidden bootstrap window
        // before its pane is presented. Keep the model resident, but do not
        // spend a scheduler slot on a native surface until the pane is visible.
        // Headless test hosts have no window and retain direct semantics.
        guard (rendererPortalVisible || view.window == nil), rendererWindowVisible else { return }
        restoredRuntimeSurfaceStartQueued = true
        let surfaceId = id
        restoreSpawnScheduler.scheduleRestoredSurfaceSpawn(
            surfaceId: surfaceId,
            resumesAgent: restoredSpawnResumesAgent
        ) { [weak self, weak view] in
            guard let self else { return }
            self.restoredRuntimeSurfaceStartQueued = false
            guard self.allowsRuntimeSurfaceCreation() else { return }
            guard self.surface == nil else { return }
            guard let view, view.window != nil else { return }
            guard self.attachedView === view else { return }
            // Visibility may change during the inter-spawn cooldown. Do not
            // turn a hidden restore admission into a native Ghostty surface;
            // the next portal/window reveal retries through the visibility
            // hook in TerminalSurface+Renderer.
            guard self.rendererPortalVisible,
                  !self.isHeadlessStartupWindow(view.window),
                  self.rendererWindowVisible else { return }
            self.createSurface(for: view, source: .scheduledRestore)
        }
    }
}
