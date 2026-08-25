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
    typealias TextSaver = @Sendable (
        String,
        URL,
        String.Encoding
    ) async -> FilePreviewTextSaver.Result

    private struct Entry {
        var lastObservedState: FilePreviewFileState
        let watcher: FileWatcher?
        let watchTask: Task<Void, Never>?
        var observers: [UUID: ChangeHandler]
    }

    /// The app-wide pipeline. A commit signal must reach every panel showing
    /// the path — across workspaces, windows, and window Docks — so production
    /// containers default to this instance; per-instance construction exists
    /// for tests.
    static let shared = FileContentChangeCoordinator()

    private let makeFileWatcher: FileWatcherFactory
    private var entriesByPath: [String: Entry] = [:]
    private var pathsByObservationID: [UUID: String] = [:]

    init(
        makeFileWatcher: @escaping FileWatcherFactory = { path in
            // The throttle bounds reload storms from external write bursts;
            // in-app saves bypass it via `fileWriteCompleted`.
            FileWatcher(path: path, throttle: .milliseconds(300))
        }
    ) {
        self.makeFileWatcher = makeFileWatcher
    }

    /// Starts observing `path`, performs one initial reconciliation, and returns
    /// an id used to remove the callback. Source attachment and registration are
    /// synchronous on the main actor, so a save cannot race ahead of a newly
    /// constructed panel.
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
        let publishedChange = publishFilesystemChangeIfNeeded(at: canonicalPath)
        if !publishedChange {
            onChange()
        }
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

    /// Runs a text save and publishes its committed write through the same path
    /// used by filesystem invalidations. Publication is independent of the
    /// saving panel's lifetime.
    func saveTextContent(
        _ content: String,
        to url: URL,
        encoding: String.Encoding,
        using saver: TextSaver,
        excluding excludedObservationID: UUID?
    ) async -> FilePreviewTextSaver.Result {
        let result = await saver(content, url, encoding)
        if case .saved = result {
            fileWriteCompleted(
                at: url.path,
                excluding: excludedObservationID
            )
        }
        return result
    }

    func saveTextContent(
        _ content: String,
        to url: URL,
        encoding: String.Encoding,
        excluding excludedObservationID: UUID?
    ) async -> FilePreviewTextSaver.Result {
        await saveTextContent(
            content,
            to: url,
            encoding: encoding,
            using: { content, url, encoding in
                await FilePreviewTextSaver.save(
                    content: content,
                    to: url,
                    encoding: encoding
                )
            },
            excluding: excludedObservationID
        )
    }

    /// If a saving panel moved while its write was suspended, mirrors the
    /// committed-write signal into the panel's current observation domain.
    func republishSuccessfulSaveIfNeeded(
        _ result: FilePreviewTextSaver.Result,
        to currentCoordinator: FileContentChangeCoordinator,
        at path: String,
        excluding currentObservationID: UUID?
    ) {
        guard case .saved = result, currentCoordinator !== self else { return }
        currentCoordinator.fileWriteCompleted(
            at: path,
            excluding: currentObservationID
        )
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

    @discardableResult
    private func publishFilesystemChangeIfNeeded(at canonicalPath: String) -> Bool {
        guard var entry = entriesByPath[canonicalPath] else { return false }
        let nextState = FilePreviewFileState.capture(path: canonicalPath)
        guard nextState != entry.lastObservedState else { return false }
        entry.lastObservedState = nextState
        let handlers = Array(entry.observers.values)
        entriesByPath[canonicalPath] = entry
        for handler in handlers {
            handler()
        }
        return true
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
