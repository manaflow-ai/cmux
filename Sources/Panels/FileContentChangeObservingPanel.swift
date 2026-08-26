import Foundation

/// Provides one shared observation lifecycle for file-backed panel surfaces.
@MainActor
protocol FileContentChangeObservingPanel: AnyObject {
    var filePath: String { get }
    var fileContentChangeCoordinator: FileContentChangeCoordinator { get set }
    var fileContentObservationID: UUID? { get set }
    var lastObservedFileState: FilePreviewFileState? { get set }
    var isClosed: Bool { get }
    var isSaving: Bool { get }

    /// Reloads this panel after the shared coordinator confirms a file change.
    @discardableResult
    func reloadFromObservedFileChange() -> Task<Void, Never>?

    /// Cancels panel-specific reload work when observation stops.
    func cancelObservedFileReload()

    /// Removes coordinator ownership before an unattached panel is discarded.
    func stopWatchingForFileChanges()
}

extension FileContentChangeObservingPanel {
    /// Registers this panel with the shared canonical-path change pipeline.
    func startWatchingForFileChanges() {
        stopWatchingForFileChanges()
        fileContentObservationID = fileContentChangeCoordinator.observe(
            path: filePath
        ) { [weak self] in
            guard let self, !self.isClosed else { return }
            _ = self.handleObservedFileChange()
        }
    }

    /// Reloads only after the observed file fingerprint advances.
    @discardableResult
    func handleObservedFileChange() -> Task<Void, Never>? {
        let state = FilePreviewFileState.capture(path: filePath)
        guard state != lastObservedFileState, !isSaving else { return nil }
        lastObservedFileState = state
        return reloadFromObservedFileChange()
    }

    /// Removes the coordinator registration and cancels panel-specific reload work.
    func stopWatchingForFileChanges() {
        if let fileContentObservationID {
            self.fileContentObservationID = nil
            fileContentChangeCoordinator.removeObservation(fileContentObservationID)
        }
        cancelObservedFileReload()
    }

    func cancelObservedFileReload() {}
}
