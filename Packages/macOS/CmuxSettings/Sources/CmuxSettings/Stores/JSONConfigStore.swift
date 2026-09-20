import CmuxFoundation
import Foundation

/// Typed read/write/observe access to settings persisted in the cmux JSON config file.
///
/// The store is an `actor`. All reads, writes, and reset are `async`, serialized
/// through actor isolation. The store only accepts ``JSONKey``; a ``DefaultsKey``
/// is rejected at compile time. There are no runtime store/key-mismatch traps.
///
/// For the rare caller that has no `await` available — e.g. a `@MainActor`
/// window-creation hook that must read a value before its first suspension point
/// — ``snapshotValue(for:)`` is a `nonisolated` synchronous read. It reads the
/// (small) config file directly rather than sharing the actor's cache, so it
/// needs no lock and always reflects what is on disk. Callers that *can* `await`
/// should use ``value(for:)``, which is backed by the in-memory cache.
///
/// JSONC (`// line` and `/* block */` comments, trailing commas) is tolerated
/// on read via the injected ``JSONCSanitizer``. Set/reset operations edit the
/// targeted object path in the original source text so comments, ordering, and
/// unrelated formatting survive ordinary Settings writes.
///
/// Observation uses a primary ``CmuxFileWatch/FileWatcher`` on the configured
/// path and, when that path resolves elsewhere, a secondary watcher on the
/// resolved target. Both fan out file-change events to per-subscriber
/// `AsyncStream<Void>` signals. A single filesystem change may fire both
/// watchers; cache invalidation is idempotent, subscriber signals are
/// coalesced, and each subscriber dedups on its own typed value so only real
/// changes propagate.
///
/// ```swift
/// let catalog = SettingCatalog()
/// let store = JSONConfigStore(fileURL: CmuxConfigLocation().userConfigFile)
/// try await store.set("hunter2", for: catalog.automationSocketPassword)
/// for await password in store.values(for: catalog.automationSocketPassword) {
///     credentialsCache.apply(password)
/// }
/// ```
public actor JSONConfigStore {
    /// The on-disk location this store reads and writes.
    public nonisolated let fileURL: URL

    private let sanitizer: JSONCSanitizer
    private let sourceEditor: JSONCPathEditor
    private let watcher: FileWatcher
    private var targetWatcher: FileWatcher?
    private var watchedTargetPath: String?

    private var cachedRoot: [String: Any] = [:]
    private var cacheValid = false
    // Resolution identity the cache was loaded under. A cmux.json symlink can be
    // retargeted at any time without a watcher event having been processed (or
    // with no subscriber at all, since drains spawn on first subscribe), so
    // cacheValid alone must never authorize reusing a root that was read from a
    // different resolved file.
    private var cachedRootResolvedPath: String?
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var watcherTask: Task<Void, Never>?
    private var targetWatcherTask: Task<Void, Never>?

    /// Creates a store backed by a JSON file at the given location.
    ///
    /// The file may be missing; reads return the key's default value and
    /// writes create the file (and any missing parent directories).
    ///
    /// - Parameters:
    ///   - fileURL: The on-disk location. Use
    ///     ``CmuxConfigLocation/userConfigFile`` for the standard cmux path.
    ///   - sanitizer: JSONC sanitizer applied to file contents on read.
    ///     Inject a custom one in tests; the default is enough for normal use.
    public init(fileURL: URL, sanitizer: JSONCSanitizer = JSONCSanitizer()) {
        self.fileURL = fileURL
        self.sanitizer = sanitizer
        self.sourceEditor = JSONCPathEditor()
        // The primary watcher observes the configured path, including symlink
        // replacement/retarget events in its parent directory. A secondary
        // target watcher observes edits that land in the resolved target's own
        // directory, which the configured-path watch cannot see.
        self.watcher = FileWatcher(path: fileURL.path)
        let resolved = Self.resolvedWriteURL(for: fileURL)
        if resolved.path != fileURL.path {
            self.targetWatcher = FileWatcher(path: resolved.path)
            self.watchedTargetPath = resolved.path
        }
    }

    deinit {
        watcherTask?.cancel()
        targetWatcherTask?.cancel()
    }

    /// Returns the current value for the key.
    public func value<Value>(for key: JSONKey<Value>) -> Value {
        let root = loadedRoot()
        let raw = key.path.lookup(in: root)
        return Value.decodeFromJSON(raw) ?? key.defaultValue
    }

    /// Synchronously returns the current value for `key`, read directly from the
    /// config file without hopping onto the actor.
    ///
    /// Use this only where an `await` is impossible — for example a `@MainActor`
    /// window-creation hook that must read a value before its first suspension
    /// point. It re-reads the (small) config file each call rather than sharing
    /// the actor's cache, so it stays lock-free and always reflects what is on
    /// disk, at the cost of a file read per call. Writes are atomic (temp +
    /// rename), so a concurrent read sees either the whole old or whole new file.
    /// Callers that *can* `await` should prefer ``value(for:)``, which is cached.
    public nonisolated func snapshotValue<Value>(for key: JSONKey<Value>) -> Value {
        let root = (try? readFromDisk()) ?? [:]
        let raw = key.path.lookup(in: root)
        return Value.decodeFromJSON(raw) ?? key.defaultValue
    }

    /// Writes a value for the key.
    ///
    /// Creates the parent directory and the file if missing. Retains the legacy
    /// syntax-only validation contract; use ``setWithReceipt(_:for:)`` for full
    /// canonical global-config validation and conditional undo. All mutations
    /// participate in the same cooperative writer boundary.
    ///
    /// - Throws: A busy/source conflict, parse/edit error, or filesystem error.
    public func set<Value>(_ value: Value, for key: JSONKey<Value>) throws {
        _ = try mutateRoot(path: key.path, value: value.encodeForJSON(), validateSemantics: false)
    }

    /// Persists a value and returns a local conditional-undo receipt.
    ///
    /// Validates the full candidate against the canonical global config schema.
    ///
    /// - Parameters:
    ///   - value: The explicit value to install, including an explicit default.
    ///   - key: The existing typed setting key.
    /// - Returns: Persisted before/installed values; runtime application is unobserved.
    /// - Throws: Conflict, validation, parsing, or filesystem errors without publication.
    public func setWithReceipt<Value>(_ value: Value, for key: JSONKey<Value>) throws -> JSONConfigMutationReceipt {
        try mutateRoot(path: key.path, value: value.encodeForJSON())
    }

    /// Removes the explicit value, preserving existing inheritance and parent pruning.
    ///
    /// Retains legacy syntax-only validation. Plain empty parents are pruned;
    /// comment-only parents remain. This is an unconditional reset, not undo.
    ///
    /// - Parameter key: The setting to reset.
    /// - Throws: Conflict, validation, parsing, or filesystem errors.
    public func reset<Value>(_ key: JSONKey<Value>) throws {
        _ = try mutateRoot(path: key.path, value: nil, validateSemantics: false)
    }

    /// Resets a setting and returns a receipt that distinguishes absence from a pin.
    ///
    /// Validates the full candidate against the canonical global config schema.
    ///
    /// - Parameter key: The setting to reset.
    /// - Returns: A local receipt; no runtime application is asserted.
    /// - Throws: Conflict, validation, parsing, or filesystem errors.
    public func resetWithReceipt<Value>(_ key: JSONKey<Value>) throws -> JSONConfigMutationReceipt {
        try mutateRoot(path: key.path, value: nil)
    }

    /// Restores only a path whose current raw value still equals the installed value.
    ///
    /// Comparison and full canonical validation share the cooperative writer lock.
    ///
    /// - Parameter receipt: A receipt from this target; never a whole-file backup.
    /// - Returns: The inverse persisted mutation, suitable for conditional redo.
    /// - Throws: An undo conflict with local preview values if ownership was lost.
    public func undo(_ receipt: JSONConfigMutationReceipt) throws -> JSONConfigMutationReceipt {
        let value = try receipt.before.map { try JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        return try mutateRoot(path: JSONPath(dottedPath: receipt.path), value: value, undoing: receipt)
    }

    /// Returns an `AsyncStream` that yields the current value and every later change.
    ///
    /// - First element is yielded as soon as the consumer starts iterating.
    /// - Subsequent elements are yielded only when the typed value at this
    ///   key's path differs from the previously yielded value.
    /// - Cancelling the consuming `Task` deregisters this subscriber. The
    ///   internal signal task breaks on the next suspension, calls
    ///   ``removeSubscriber(id:)``, and finishes the stream. Safe to cancel
    ///   at any time, including before the first value is yielded.
    /// - The internal change-signal stream uses `.bufferingNewest(1)`; bursts
    ///   of file events coalesce, since we only care that *something*
    ///   changed and re-read the typed value on each consumed signal.
    public nonisolated func values<Value>(for key: JSONKey<Value>) -> AsyncStream<Value> {
        AsyncStream<Value> { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                let initial = await self.value(for: key)
                continuation.yield(initial)

                let id = UUID()
                // bufferingNewest(1): the signal carries no payload, so under
                // burst file changes we only care that *something* changed.
                // Dropping intermediate signals is correct because the typed
                // value is re-read on every consumed signal and deduped below.
                // Bounded buffering prevents unbounded growth under load.
                let (signal, signalContinuation) = AsyncStream<Void>.makeStream(
                    bufferingPolicy: .bufferingNewest(1)
                )
                await self.addSubscriber(id: id, continuation: signalContinuation)

                var last = initial
                for await _ in signal {
                    if Task.isCancelled { break }
                    let current = await self.value(for: key)
                    if current != last {
                        last = current
                        continuation.yield(current)
                    }
                }
                await self.removeSubscriber(id: id)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private

    private func addSubscriber(id: UUID, continuation: AsyncStream<Void>.Continuation) {
        subscribers[id] = continuation
        ensureWatcherTask()
    }

    private func removeSubscriber(id: UUID) {
        if let cont = subscribers.removeValue(forKey: id) {
            cont.finish()
        }
    }

    /// Spawns watcher-consumer tasks on the first subscribe. Each task drains a
    /// ``CmuxFileWatch/FileWatcher`` and fans out to every registered
    /// subscriber after invalidating the cache.
    private func ensureWatcherTask() {
        guard watcherTask == nil else { return }
        watcherTask = drainTask(for: watcher)
        if let targetWatcher {
            targetWatcherTask = drainTask(for: targetWatcher)
        }
    }

    private func drainTask(for watcher: FileWatcher) -> Task<Void, Never> {
        Task { [weak self] in
            for await _ in watcher.events {
                if Task.isCancelled { break }
                guard let self else { break }
                await self.handleFileChange()
            }
        }
    }

    private func handleFileChange() {
        cacheValid = false
        refreshTargetWatcher()
        for continuation in subscribers.values {
            continuation.yield(())
        }
    }

    /// Keeps the secondary watcher following a retargeted configured symlink.
    ///
    /// Without this refresh, edits in the new target's own directory go
    /// unobserved after a dotfiles tool swaps the configured link. Cancelling the
    /// old drain task releases the previous watcher; `FileWatcher` tears down
    /// its dispatch sources on deinit.
    private func refreshTargetWatcher() {
        let resolved = Self.resolvedWriteURL(for: fileURL)
        let desired: String? = resolved.path == fileURL.path ? nil : resolved.path
        guard desired != watchedTargetPath else { return }

        targetWatcherTask?.cancel()
        targetWatcherTask = nil
        targetWatcher = nil
        watchedTargetPath = desired

        guard let desired else { return }
        let replacement = FileWatcher(path: desired)
        targetWatcher = replacement
        if watcherTask != nil {
            targetWatcherTask = drainTask(for: replacement)
        }
    }

    private func loadedRoot() -> [String: Any] {
        let resolvedURL = Self.resolvedWriteURL(for: fileURL)
        if cacheIsCurrent(for: resolvedURL.path) { return cachedRoot }
        cachedRoot = (try? readFromDisk(at: resolvedURL)) ?? [:]
        cacheValid = true
        cachedRootResolvedPath = resolvedURL.path
        return cachedRoot
    }

    private func cacheIsCurrent(for resolvedPath: String) -> Bool {
        cacheValid && cachedRootResolvedPath == resolvedPath
    }

    /// Reads and decodes the config root from disk. A missing or empty file
    /// decodes to an empty root; a present-but-unparseable file throws so
    /// callers can refuse to overwrite it. `nonisolated` so the synchronous
    /// ``snapshotValue(for:)`` can call it without hopping onto the actor; it
    /// only touches the `nonisolated` `fileURL` and the `Sendable` `sanitizer`.
    private nonisolated func readFromDisk() throws -> [String: Any] {
        try readFromDisk(at: fileURL)
    }

    private nonisolated func readFromDisk(at url: URL) throws -> [String: Any] {
        try readDocument(at: url).root
    }

    /// Reads the parsed root and, for an existing non-empty file, its original
    /// source text from one disk snapshot.
    private nonisolated func readDocument(
        at url: URL
    ) throws -> (root: [String: Any], source: String?, originalData: Data?) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return ([:], nil, nil)
        }
        if data.isEmpty { return ([:], "", data) }

        let source = try sanitizer.sourceText(from: data)
        let sanitized = try sanitizer.sanitize(data)
        let object = try JSONSerialization.jsonObject(with: sanitized, options: [])
        guard let dictionary = object as? [String: Any] else {
            throw JSONConfigStoreReadError.notADictionary
        }
        return (dictionary, source, data)
    }

    /// Resolves the location a write should target for `url`.
    ///
    /// When `url` is a symlink — e.g. a `cmux.json` symlinked into a dotfiles
    /// repo — an atomic write (`options: [.atomic]`) does a temp-file
    /// `rename()` onto the link path, which *replaces the symlink with a
    /// regular file* and silently breaks the dotfiles setup. Following the link
    /// to its target means the atomic replace lands on the target file, leaving
    /// the symlink intact. Non-symlink and missing paths are returned
    /// unchanged, so plain files (and first-time creation) still write in place.
    ///
    /// Mirrors `ConfigSource.configWriteURL(for:)`, which already does this for
    /// the ghostty-format config surface; the JSON store had not been given the
    /// same treatment.
    private static func resolvedWriteURL(
        for url: URL,
        fileManager: FileManager = .default
    ) -> URL {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return url
        }
        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = url.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return destinationURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Re-read, prepare, validate and publish inside the cooperative writer boundary.
    /// Arbitrary editors do not take this lock; the final source check narrows but
    /// cannot eliminate their race with the atomic rename.
    private func mutateRoot(
        path: JSONPath,
        value: Any?,
        undoing: JSONConfigMutationReceipt? = nil,
        validateSemantics: Bool = true
    ) throws -> JSONConfigMutationReceipt {
        let writeURL = Self.resolvedWriteURL(for: fileURL)
        let lock = try JSONConfigWriteLock(target: writeURL)
        defer { lock.release() }
        guard Self.resolvedWriteURL(for: fileURL) == writeURL else {
            throw JSONConfigMutationError.sourceChanged
        }
        let identity = try fileIdentity(at: writeURL)
        let document = try readDocument(at: writeURL)
        let before = try JSONConfigMutationReceipt.encode(path.lookup(in: document.root))
        if let undoing, undoing.target != writeURL || before != undoing.installed {
            throw JSONConfigMutationError.undoConflict(
                path: undoing.path, expected: undoing.installed, current: before, restore: undoing.before
            )
        }
        var candidateRoot = document.root
        if let value { path.assign(value, in: &candidateRoot) }
        else { path.remove(in: &candidateRoot) }
        let receipt = JSONConfigMutationReceipt(
            path: path.components.joined(separator: "."), before: before,
            installed: try JSONConfigMutationReceipt.encode(path.lookup(in: candidateRoot)), target: writeURL
        )
        guard !Self.jsonObjectsEqual(document.root, candidateRoot) else {
            if validateSemantics {
                let issues = CmuxConfigSemanticValidator(scope: .global).validate(jsonObject: candidateRoot)
                guard issues.isEmpty else { throw JSONConfigMutationError.invalidCandidate(issues) }
            }
            cachedRoot = document.root
            cacheValid = true
            cachedRootResolvedPath = writeURL.path
            return receipt
        }
        let source = document.source.flatMap { $0.isEmpty ? nil : $0 } ?? "{\n}\n"
        let updated: String
        if let value {
            updated = try sourceEditor.set(path: path.components, value: .init(rawValue: value), in: source)
        } else {
            updated = try sourceEditor.remove(path: path.components, in: source)
        }
        let data = try sanitizer.encodedSource(updated, preserving: document.originalData)
        let sanitized = try sanitizer.sanitize(data)
        let object = try JSONSerialization.jsonObject(with: sanitized)
        guard let persistedRoot = object as? [String: Any] else {
            throw JSONConfigStoreReadError.notADictionary
        }
        if validateSemantics {
            let issues = CmuxConfigSemanticValidator(scope: .global).validate(jsonObject: persistedRoot)
            guard issues.isEmpty else { throw JSONConfigMutationError.invalidCandidate(issues) }
        }
        guard Self.resolvedWriteURL(for: fileURL) == writeURL,
              try fileIdentity(at: writeURL) == identity,
              try readDocument(at: writeURL).originalData == document.originalData else {
            throw JSONConfigMutationError.sourceChanged
        }
        try data.write(to: writeURL, options: [.atomic])
        cachedRoot = persistedRoot
        cacheValid = true
        cachedRootResolvedPath = writeURL.path
        for continuation in subscribers.values { continuation.yield(()) }
        return receipt
    }

    /// Detect replacement even when an external editor republishes identical bytes.
    private func fileIdentity(at url: URL) throws -> String? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return "\(String(describing: attributes[.systemNumber])):\(String(describing: attributes[.systemFileNumber]))"
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }

    private static func jsonObjectsEqual(
        _ lhs: [String: Any],
        _ rhs: [String: Any]
    ) -> Bool {
        guard let left = try? JSONSerialization.data(
            withJSONObject: lhs,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ),
        let right = try? JSONSerialization.data(
            withJSONObject: rhs,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            return false
        }
        return left == right
    }
}
