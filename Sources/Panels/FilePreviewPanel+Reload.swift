import CmuxFoundation
import Foundation

extension FilePreviewPanel {
    /// Starts one panel-scoped filesystem observation task. `FileWatcher`
    /// handles atomic replacement and delete/recreate recovery for the path.
    func startWatchingForFileChanges() {
        stopWatchingForFileChanges()
        lastObservedFileState = .capture(path: filePath)
        let watcher = FileWatcher(path: filePath, throttle: .milliseconds(300))
        fileChangeWatcher = watcher
        let events = watcher.events
        fileChangeTask = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self, !self.isClosed else { break }
                self.handleObservedFileChange()
            }
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
        fileChangeTask?.cancel()
        fileChangeTask = nil
        fileChangeReloadTask?.cancel()
        fileChangeReloadTask = nil
        // Dropping the watcher cancels its DispatchSources.
        fileChangeWatcher = nil
    }
}
