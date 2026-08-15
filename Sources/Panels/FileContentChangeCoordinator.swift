import CmuxFoundation
import Foundation

/// Multiplexes file-content invalidations for file-backed panels.
///
/// Each canonical path owns one filesystem watcher regardless of how many
/// panels display it. Successful in-app writes also enter through this service,
/// giving viewers a commit-boundary signal that does not depend on vnode event
/// timing. Filesystem events remain the fallback for external editors.
@MainActor
final class FileContentChangeCoordinator {
    typealias ChangeHandler = @MainActor () -> Void
    typealias FileWatcherFactory = @MainActor (String) -> FileWatcher?

    private struct Entry {
        var lastObservedState: FilePreviewFileState
        let watcher: FileWatcher?
        let watchTask: Task<Void, Never>?
        var observers: [UUID: ChangeHandler]
    }

    private let makeFileWatcher: FileWatcherFactory
    private var entriesByPath: [String: Entry] = [:]
    private var pathsByObservationID: [UUID: String] = [:]

    init(
        makeFileWatcher: @escaping FileWatcherFactory = { path in
            FileWatcher(path: path)
        }
    ) {
        self.makeFileWatcher = makeFileWatcher
    }

    /// Starts observing `path` and returns an id used to remove the callback.
    /// Source attachment and callback registration are synchronous on the main
    /// actor, so a save cannot race ahead of a newly constructed panel.
    func observe(
        path: String,
        onChange: @escaping ChangeHandler
    ) -> UUID {
        let canonicalPath = Self.canonicalPath(path)
        let observationID = UUID()
        var entry = entriesByPath[canonicalPath]
            ?? makeEntry(for: canonicalPath)
        entry.observers[observationID] = onChange
        entriesByPath[canonicalPath] = entry
        pathsByObservationID[observationID] = canonicalPath

        // Close the capture/attachment gap: the first fingerprint is sampled
        // before watcher construction and this second sample happens after the
        // observer is installed. Changes after attachment arrive on the stream.
        publishFilesystemChangeIfNeeded(at: canonicalPath)
        return observationID
    }

    func removeObservation(_ observationID: UUID) {
        guard let canonicalPath = pathsByObservationID.removeValue(
            forKey: observationID
        ), var entry = entriesByPath[canonicalPath] else {
            return
        }
        entry.observers.removeValue(forKey: observationID)
        guard entry.observers.isEmpty else {
            entriesByPath[canonicalPath] = entry
            return
        }
        entriesByPath.removeValue(forKey: canonicalPath)
        entry.watchTask?.cancel()
    }

    /// Publishes only after an in-app writer has successfully committed bytes.
    /// The writing panel can be excluded because it already owns authoritative
    /// editor state and may perform its own post-save reconciliation.
    func fileWriteCompleted(
        at path: String,
        excluding excludedObservationID: UUID? = nil
    ) {
        let canonicalPath = Self.canonicalPath(path)
        guard var entry = entriesByPath[canonicalPath] else { return }
        entry.lastObservedState = .capture(path: canonicalPath)
        let handlers = entry.observers.compactMap { observationID, handler in
            observationID == excludedObservationID ? nil : handler
        }
        entriesByPath[canonicalPath] = entry
        for handler in handlers {
            handler()
        }
    }

    deinit {
        for entry in entriesByPath.values {
            entry.watchTask?.cancel()
        }
    }

    private func makeEntry(for canonicalPath: String) -> Entry {
        let initialState = FilePreviewFileState.capture(path: canonicalPath)
        let watcher = makeFileWatcher(canonicalPath)
        let watchTask = watcher.map { watcher in
            Task { @MainActor [weak self] in
                for await _ in watcher.events {
                    guard !Task.isCancelled else { return }
                    self?.publishFilesystemChangeIfNeeded(at: canonicalPath)
                }
            }
        }
        return Entry(
            lastObservedState: initialState,
            watcher: watcher,
            watchTask: watchTask,
            observers: [:]
        )
    }

    private func publishFilesystemChangeIfNeeded(at canonicalPath: String) {
        guard var entry = entriesByPath[canonicalPath] else { return }
        let nextState = FilePreviewFileState.capture(path: canonicalPath)
        guard nextState != entry.lastObservedState else { return }
        entry.lastObservedState = nextState
        let handlers = Array(entry.observers.values)
        entriesByPath[canonicalPath] = entry
        for handler in handlers {
            handler()
        }
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
