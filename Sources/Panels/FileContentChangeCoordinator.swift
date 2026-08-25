import CmuxFoundation
import Foundation

/// Multiplexes file-content invalidations for file-backed panels.
///
/// Each canonical target owns a stable-path watcher plus one watcher for every
/// presented alias. Successful in-app writes also enter through this service,
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

    private typealias WatchRegistration = (
        watcher: FileWatcher?,
        task: Task<Void, Never>?
    )

    /// Private storage for one canonical path; it has no independent lifecycle
    /// or consumer, so keeping it nested preserves the coordinator's ownership
    /// boundary instead of introducing another app-target type.
    private struct Entry {
        /// Fingerprints are tracked per watched path because an alias can be
        /// retargeted while a panel opened through the real path remains valid.
        var lastObservedStates: [String: FilePreviewFileState] = [:]
        var watches: [String: WatchRegistration] = [:]
        var observers: [UUID: ChangeHandler] = [:]
    }

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
        let watchedPath = Self.standardizedPath(path)
        let observationID = UUID()
        var entry = entriesByPath[canonicalPath]
            ?? Entry()
        installWatch(
            for: watchedPath,
            canonicalPath: canonicalPath,
            in: &entry
        )
        if watchedPath != canonicalPath {
            // Keep the original target alive even if the first alias is
            // replaced or retargeted. Alias events still refresh panels that
            // resolve through the alias, while real-path panels keep watching
            // the inode they opened.
            installWatch(
                for: canonicalPath,
                canonicalPath: canonicalPath,
                in: &entry
            )
        }
        entry.observers[observationID] = onChange
        entriesByPath[canonicalPath] = entry
        pathsByObservationID[observationID] = canonicalPath

        // Close the capture/attachment gap: the first fingerprint is sampled
        // before watcher construction and this second sample happens after the
        // observer is installed. Changes after attachment arrive on the stream.
        let publishedChange = publishFilesystemChangeIfNeeded(
            at: canonicalPath,
            watchedPath: watchedPath
        )
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
        for registration in entry.watches.values {
            registration.task?.cancel()
        }
    }

    /// Publishes only after an in-app writer has successfully committed bytes.
    /// The writing panel can be excluded because it already owns authoritative
    /// editor state and may perform its own post-save reconciliation.
    func fileWriteCompleted(
        at path: String,
        excluding excludedObservationID: UUID? = nil
    ) {
        let canonicalPath = Self.canonicalPath(path)
        let watchedPath = Self.standardizedPath(path)
        let matchingEntryKeys = entriesByPath.compactMap { entryKey, entry in
            guard entryKey == canonicalPath
                || entry.lastObservedStates[watchedPath] != nil
                || entry.lastObservedStates[canonicalPath] != nil
                || entry.lastObservedStates.keys.contains(where: {
                    Self.canonicalPath($0) == canonicalPath
                }) else {
                return nil
            }
            return entryKey
        }
        for entryKey in matchingEntryKeys {
            guard var entry = entriesByPath[entryKey] else { continue }
            for watchPath in Array(entry.lastObservedStates.keys) {
                entry.lastObservedStates[watchPath] = .capture(path: watchPath)
            }
            let handlers = entry.observers.compactMap { observationID, handler in
                observationID == excludedObservationID ? nil : handler
            }
            entriesByPath[entryKey] = entry
            for handler in handlers {
                handler()
            }
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
            for registration in entry.watches.values {
                registration.task?.cancel()
            }
        }
    }

    private func installWatch(
        for watchedPath: String,
        canonicalPath: String,
        in entry: inout Entry
    ) {
        guard entry.watches[watchedPath] == nil else { return }
        entry.lastObservedStates[watchedPath] = .capture(path: watchedPath)
        entry.watches[watchedPath] = makeWatchRegistration(
            for: watchedPath,
            canonicalPath: canonicalPath
        )
    }

    private func makeWatchRegistration(
        for watchedPath: String,
        canonicalPath: String
    ) -> WatchRegistration {
        let watcher = makeFileWatcher(watchedPath)
        let watchTask = watcher.map { watcher in
            Task { @MainActor [weak self] in
                for await _ in watcher.events {
                    guard !Task.isCancelled else { return }
                    self?.publishFilesystemChangeIfNeeded(
                        at: canonicalPath,
                        watchedPath: watchedPath
                    )
                }
            }
        }
        return (watcher: watcher, task: watchTask)
    }

    @discardableResult
    private func publishFilesystemChangeIfNeeded(
        at canonicalPath: String,
        watchedPath: String
    ) -> Bool {
        guard var entry = entriesByPath[canonicalPath],
              let lastObservedState = entry.lastObservedStates[watchedPath] else {
            return false
        }
        let nextState = FilePreviewFileState.capture(path: watchedPath)
        guard nextState != lastObservedState else { return false }
        entry.lastObservedStates[watchedPath] = nextState
        let handlers = Array(entry.observers.values)
        entriesByPath[canonicalPath] = entry
        for handler in handlers {
            handler()
        }
        return true
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: standardizedPath(path))
            .resolvingSymlinksInPath()
            .path
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
