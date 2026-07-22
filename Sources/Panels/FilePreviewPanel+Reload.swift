import CmuxFoundation

extension FilePreviewPanel {
    /// Starts one panel-scoped filesystem observation task. `FileWatcher`
    /// handles atomic replacement and delete/recreate recovery for the path.
    func startWatchingForFileChanges() {
        stopWatchingForFileChanges()
        let watcher = FileWatcher(path: filePath)
        fileChangeWatcher = watcher
        let events = watcher.events
        fileChangeTask = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self, !self.isClosed else { break }
                self.reloadFromDisk()
            }
        }
    }

    func stopWatchingForFileChanges() {
        fileChangeTask?.cancel()
        fileChangeTask = nil
        // Dropping the watcher cancels its DispatchSources.
        fileChangeWatcher = nil
    }
}
