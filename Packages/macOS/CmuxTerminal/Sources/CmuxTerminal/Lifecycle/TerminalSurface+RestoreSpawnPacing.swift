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
        // Keep the logical admission queued even while the model is attached
        // to cmux's hidden bootstrap window. The callback below re-checks
        // visibility before entering Ghostty, and a later portal/window reveal
        // retries the native admission. This preserves restore ordering and
        // keeps session state resident without hidden renderer fan-out.
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
            // Non-portal/headless hosts (including the startup-policy test
            // harness) retain their direct admission semantics. A real
            // portal-owned pane must be visible before Ghostty is entered.
            guard self.rendererPortalVisible || !view.paneGeometryIsPortalOwned,
                  self.rendererWindowVisible else { return }
            self.createSurface(for: view, source: .scheduledRestore)
        }
    }
}
