extension TerminalSurface {
    @MainActor
    func shouldPaceRuntimeSurfaceCreation(source: RuntimeSurfaceCreationSource) -> Bool {
        guard requiresRestoreSpawnPacing else { return false }
        guard source == .normal else { return false }
        guard surface == nil else { return false }
        return true
    }

    @MainActor
    func enqueueRestoredRuntimeSurfaceCreation(for view: any TerminalSurfaceNativeViewing) {
        guard !restoredRuntimeSurfaceStartQueued else { return }
        restoredRuntimeSurfaceStartQueued = true
        let surfaceId = id
        restoreSpawnScheduler.scheduleRestoredSurfaceSpawn(surfaceId: surfaceId) { [weak self, weak view] in
            guard let self else { return }
            self.restoredRuntimeSurfaceStartQueued = false
            guard self.allowsRuntimeSurfaceCreation() else { return }
            guard self.surface == nil else { return }
            guard let view, view.window != nil else { return }
            guard self.attachedView === view else { return }
            self.createSurface(for: view, source: .scheduledRestore)
        }
    }
}
