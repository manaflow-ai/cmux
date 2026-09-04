import Foundation

extension FilePreviewPanel {
    /// Starts the latest file-preview reload after a shared observation event.
    @discardableResult
    func reloadFromObservedFileChange() -> Task<Void, Never>? {
        cancelObservedFileReload()
        let task = reloadFromDisk()
        fileChangeReloadTask = task
        return task
    }

    func cancelObservedFileReload() {
        fileChangeReloadTask?.cancel()
        fileChangeReloadTask = nil
    }
}
