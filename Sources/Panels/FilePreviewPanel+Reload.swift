import Foundation

extension FilePreviewPanel {
    /// Registers this panel with the workspace's shared file-change pipeline.
    func startWatchingForFileChanges() {
        stopWatchingForFileChanges()
        fileContentObservationID = fileContentChangeCoordinator.observe(
            path: filePath
        ) { [weak self] in
            guard let self, !self.isClosed else { return }
            self.handleObservedFileChange()
        }
    }

    @discardableResult
    func handleObservedFileChange() -> Task<Void, Never>? {
        let state = FilePreviewFileState.capture(path: filePath)
        guard state != lastObservedFileState else { return nil }
        guard !isSaving else { return nil }
        lastObservedFileState = state
        fileChangeReloadTask?.cancel()
        let task = reloadFromDisk()
        fileChangeReloadTask = task
        return task
    }

    func stopWatchingForFileChanges() {
        if let fileContentObservationID {
            self.fileContentObservationID = nil
            fileContentChangeCoordinator.removeObservation(fileContentObservationID)
        }
        fileChangeReloadTask?.cancel()
        fileChangeReloadTask = nil
    }
}
