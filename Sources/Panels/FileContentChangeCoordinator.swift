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

    private let makeFileWatcher: FileWatcherFactory
    private var entriesByPath: [String: Entry] = [:]
    private var observationsByID: [UUID: Observation] = [:]
    private var entryKeysByLookupPath: [String: Set<String>] = [:]

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
        refreshLookupIndex(for: canonicalPath, in: &entry)
        entriesByPath[canonicalPath] = entry
        observationsByID[observationID] = (
            canonicalPath: canonicalPath,
            watchedPath: watchedPath
        )

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
        guard let observation = observationsByID.removeValue(forKey: observationID),
              var entry = entriesByPath[observation.canonicalPath] else {
            return
        }
        entry.observers.removeValue(forKey: observationID)
        guard !entry.observers.isEmpty else {
            for registration in entry.watches.values {
                registration.task?.cancel()
            }
            entry.watches.removeAll()
            entry.lastObservedStates.removeAll()
            entry.lookupPathsByWatchedPath.removeAll()
            refreshLookupIndex(for: observation.canonicalPath, in: &entry)
            entriesByPath.removeValue(forKey: observation.canonicalPath)
            return
        }

        let remainingWatchedPaths = Set(
            observationsByID.values
                .filter { $0.canonicalPath == observation.canonicalPath }
                .map { $0.watchedPath }
        )
        var requiredWatchPaths = remainingWatchedPaths
        if remainingWatchedPaths.contains(where: { $0 != observation.canonicalPath }) {
            // Alias observers need the stable target watcher so a retargeted
            // alias cannot strand panels still showing the original inode.
            requiredWatchPaths.insert(observation.canonicalPath)
        }
        for watchPath in Array(entry.watches.keys)
            where !requiredWatchPaths.contains(watchPath) {
            if let registration = entry.watches.removeValue(forKey: watchPath) {
                registration.task?.cancel()
            }
            entry.lastObservedStates.removeValue(forKey: watchPath)
            entry.lookupPathsByWatchedPath.removeValue(forKey: watchPath)
        }
        refreshLookupIndex(for: observation.canonicalPath, in: &entry)
        entriesByPath[observation.canonicalPath] = entry
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
        let matchingEntryKeys = Set(
            (entryKeysByLookupPath[watchedPath] ?? [])
                .union(entryKeysByLookupPath[canonicalPath] ?? [])
        )
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
        entry.lookupPathsByWatchedPath[watchedPath] = [watchedPath, canonicalPath]
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
        let nextLookupPaths: Set<String> = [
            watchedPath,
            Self.canonicalPath(watchedPath)
        ]
        if entry.lookupPathsByWatchedPath[watchedPath] != nextLookupPaths {
            entry.lookupPathsByWatchedPath[watchedPath] = nextLookupPaths
            refreshLookupIndex(for: canonicalPath, in: &entry)
        }
        guard nextState != lastObservedState else {
            entriesByPath[canonicalPath] = entry
            return false
        }
        entry.lastObservedStates[watchedPath] = nextState
        let handlers = Array(entry.observers.values)
        entriesByPath[canonicalPath] = entry
        for handler in handlers {
            handler()
        }
        return true
    }

    private func refreshLookupIndex(
        for entryKey: String,
        in entry: inout Entry
    ) {
        for lookupPath in entry.indexedLookupPaths {
            guard var entryKeys = entryKeysByLookupPath[lookupPath] else { continue }
            entryKeys.remove(entryKey)
            if entryKeys.isEmpty {
                entryKeysByLookupPath.removeValue(forKey: lookupPath)
            } else {
                entryKeysByLookupPath[lookupPath] = entryKeys
            }
        }

        let nextLookupPaths = Set(
            entry.lookupPathsByWatchedPath.values.flatMap { $0 }
        )
        for lookupPath in nextLookupPaths {
            entryKeysByLookupPath[lookupPath, default: []].insert(entryKey)
        }
        entry.indexedLookupPaths = nextLookupPaths
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
