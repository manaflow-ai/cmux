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
    private let publisher: JSONConfigAtomicPublisher
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
        self.publisher = JSONConfigAtomicPublisher()
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
    /// Creates the parent directory and the file if missing. Keeps the
    /// syntax-only validation contract; use ``setWithReceipt(_:for:)`` for
    /// canonical global-config validation and conditional undo.
    ///
    /// - Throws: Errors from `FileManager` or `JSONSerialization` writing the file.
    public func set<Value>(_ value: Value, for key: JSONKey<Value>) async throws {
        _ = try await mutateRoot(path: key.path, value: value.encodeForJSON(), validateSemantics: false)
    }

    /// Persists a value and returns a local conditional-undo receipt.
    ///
    /// Validates the complete candidate against the canonical global config
    /// schema before publication and refuses only issues this change
    /// introduces. Issues the file already has, such as a key from a newer
    /// build, don't block it.
    ///
    /// - Parameters:
    ///   - value: The explicit value to install, including an explicit default.
    ///   - key: The typed setting key.
    /// - Returns: The persisted before/installed values. Runtime application is
    ///   not observed.
    /// - Throws: ``JSONConfigMutationError/invalidCandidate(_:)``, a write
    ///   conflict, or a parse/filesystem error. Nothing is published on throw.
    public func setWithReceipt<Value>(
        _ value: Value,
        for key: JSONKey<Value>
    ) async throws -> JSONConfigMutationReceipt {
        try await mutateRoot(path: key.path, value: value.encodeForJSON())
    }

    /// Removes the key's entry from the file. Plain parent objects that become
    /// empty are pruned. Comment-only parents stay in place so reset does not
    /// delete user-authored documentation. The file itself is not deleted even
    /// when no entries remain. This is an unconditional reset, not undo.
    ///
    /// - Throws: Errors from `FileManager`, JSON parsing, or the source edit.
    public func reset<Value>(_ key: JSONKey<Value>) async throws {
        _ = try await mutateRoot(path: key.path, value: nil, validateSemantics: false)
    }

    /// Resets a setting and returns a receipt that distinguishes absence from
    /// an explicit pin.
    ///
    /// Validates the complete candidate against the canonical global config
    /// schema before publication and refuses only issues this reset introduces.
    ///
    /// - Parameter key: The setting to reset.
    /// - Returns: A local receipt; runtime application is not observed.
    /// - Throws: Validation, conflict, parsing, or filesystem errors.
    public func resetWithReceipt<Value>(_ key: JSONKey<Value>) async throws -> JSONConfigMutationReceipt {
        try await mutateRoot(path: key.path, value: nil)
    }

    /// Restores the receipt's prior value only while the path still holds the
    /// value the receipt installed.
    ///
    /// The comparison, canonical validation, and publication run inside
    /// the same cooperative writer lock as every other mutation.
    ///
    /// - Parameter receipt: A receipt produced for this store's resolved target.
    /// - Returns: The inverse receipt, usable for a conditional redo.
    /// - Throws: ``JSONConfigMutationError/undoConflict(path:expected:current:restore:)``
    ///   when a newer choice owns the path or the target was retargeted; the
    ///   file is left untouched.
    public func undo(_ receipt: JSONConfigMutationReceipt) async throws -> JSONConfigMutationReceipt {
        let value = try receipt.before.map {
            try JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed])
        }
        return try await mutateRoot(
            path: JSONPath(dottedPath: receipt.path),
            value: value,
            undoing: receipt
        )
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

    /// The parsed root as it is on disk now, for synchronous readers such as
    /// ``reading(at:)``. A missing file reads as an empty root.
    nonisolated func snapshotRoot() throws -> [String: Any] {
        try readFromDisk()
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
        // Canonicalize the parent first so the native store and cmux-settings
        // helper derive one stable writer-lock path through symlinked ancestors.
        let canonical = url.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent)
            .standardizedFileURL
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: canonical.path) else {
            return canonical
        }
        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = canonical.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return destinationURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Computes the mutation, writes it to disk, and **only then** commits to
    /// the in-memory cache.
    ///
    /// If the write fails (e.g. permission denied, full disk), the cache is
    /// left untouched so subsequent reads still reflect what is actually on
    /// disk. Without this ordering, a failed write would silently leave the
    /// cache ahead of the file and reads would return phantom unsaved data.
    ///
    /// If the existing file on disk exists but cannot be parsed (corrupt
    /// JSON, malformed JSONC, top-level non-object), the write is refused
    /// — overwriting a corrupt file would silently destroy whatever real
    /// content the user has in it. The error from
    /// ``readFromDisk(at:)`` is propagated to the caller.
    ///
    /// The root must never come from a cache loaded under a different resolved
    /// target, since that would overwrite the new target's contents with the old
    /// target's data. A single mutation reads and writes through one resolution
    /// snapshot, so a concurrent retarget serializes against the write instead
    /// of splitting the operation across two targets.
    private func mutateRoot(
        path: JSONPath,
        value: Any?,
        undoing: JSONConfigMutationReceipt? = nil,
        validateSemantics: Bool = true
    ) async throws -> JSONConfigMutationReceipt {
        let receipts = try await mutateRoot(validateSemantics: validateSemantics) { root, writeURL in
            // Undo owns the path only while it still holds the installed value on
            // the same resolved target. A newer choice, or a retargeted symlink,
            // wins and the file stays byte-for-byte unchanged.
            if let undoing {
                let before = try JSONConfigMutationReceipt.encode(path.lookup(in: root))
                if undoing.target != writeURL || before != undoing.installed {
                    throw JSONConfigMutationError.undoConflict(
                        path: undoing.path,
                        expected: undoing.installed,
                        current: before,
                        restore: undoing.before
                    )
                }
            }
            return [CmuxSettingChangePlanner.Edit(path: path, value: value)]
        }
        return receipts[0]
    }

    /// Applies a setting change as one validated, atomic publication.
    ///
    /// `toggle`, `cycle`, and `preset` read the current value inside the same
    /// writer lock that publishes the result, so two quick invocations can't
    /// both read the old value. The complete candidate is validated against
    /// the canonical global schema and refused only for issues this change
    /// introduces. Comments and unrelated formatting are preserved.
    ///
    /// - Parameter change: The edit to apply.
    /// - Returns: One receipt per path the change addressed, including paths
    ///   that already held the requested value. Runtime application is not
    ///   observed; cmux's config file watcher applies the saved file.
    /// - Throws: ``CmuxSettingChangeError`` for an unknown or non-setting
    ///   path, a non-boolean toggle, or a missing preset;
    ///   ``JSONConfigMutationError/invalidCandidate(_:)`` for a value the
    ///   schema rejects; or a conflict, parse, or filesystem error. Nothing is
    ///   published on throw.
    public func apply(_ change: CmuxSettingChange) async throws -> CmuxSettingChangeResult {
        let planner = CmuxSettingChangePlanner()
        let receipts = try await mutateRoot(validateSemantics: true) { root, _ in
            try planner.edits(for: change, in: root)
        }
        return CmuxSettingChangeResult(receipts: receipts)
    }

    /// Computes the edits, writes them to disk, and **only then** commits to
    /// the in-memory cache.
    ///
    /// If the write fails (e.g. permission denied, full disk), the cache is
    /// left untouched so subsequent reads still reflect what is actually on
    /// disk. Without this ordering, a failed write would silently leave the
    /// cache ahead of the file and reads would return phantom unsaved data.
    ///
    /// If the existing file on disk exists but cannot be parsed (corrupt
    /// JSON, malformed JSONC, top-level non-object), the write is refused
    /// — overwriting a corrupt file would silently destroy whatever real
    /// content the user has in it. The error from
    /// ``readFromDisk(at:)`` is propagated to the caller.
    ///
    /// The root must never come from a cache loaded under a different resolved
    /// target, since that would overwrite the new target's contents with the old
    /// target's data. A single mutation reads and writes through one resolution
    /// snapshot, so a concurrent retarget serializes against the write instead
    /// of splitting the operation across two targets.
    ///
    /// `makeEdits` runs under the writer lock with the authoritative on-disk
    /// root and resolved target, so read-modify-write edits observe exactly
    /// the document they replace. Every edit lands in one publication.
    private func mutateRoot(
        validateSemantics: Bool,
        makeEdits: ([String: Any], URL) throws -> [CmuxSettingChangePlanner.Edit]
    ) async throws -> [JSONConfigMutationReceipt] {
        // Resolve once so parsing, source editing, and the atomic replace all
        // target the same file when cmux.json is a symlink.
        let writeURL = Self.resolvedWriteURL(for: fileURL)
        // The persisted target is the source of truth. Every participating cmux
        // writer takes this sidecar lock before its authoritative read so no
        // read-edit-replace sequence can overlap another cmux writer.
        let writeLock = try await JSONConfigWriteLock.acquire(target: writeURL)
        defer { writeLock.release() }
        guard Self.resolvedWriteURL(for: fileURL) == writeURL else {
            throw JSONConfigWriteConflict.sourceChanged
        }
        let document = try readDocument(at: writeURL)
        let edits = try makeEdits(document.root, writeURL)

        var candidateRoot = document.root
        for edit in edits {
            if let value = edit.value {
                edit.path.assign(value, in: &candidateRoot)
            } else {
                edit.path.remove(in: &candidateRoot)
            }
        }
        let receipts = try edits.map { edit in
            JSONConfigMutationReceipt(
                path: edit.path.components.joined(separator: "."),
                before: try JSONConfigMutationReceipt.encode(edit.path.lookup(in: document.root)),
                installed: try JSONConfigMutationReceipt.encode(edit.path.lookup(in: candidateRoot)),
                target: writeURL
            )
        }

        // Semantic no-ops stay byte-stable and avoid an atomic replace. Reading
        // from disk here also refreshes the cache if an external edit landed
        // before this mutation.
        guard !Self.jsonObjectsEqual(document.root, candidateRoot) else {
            // Nothing changes, so the mutation introduces no issue to refuse.
            cachedRoot = document.root
            cacheValid = true
            cachedRootResolvedPath = writeURL.path
            return receipts
        }

        // Missing/zero-byte configs have no authoring text to preserve. Seed
        // the smallest editable object and let the path editor create only the
        // requested path.
        var updatedSource: String
        if let existingSource = document.source, !existingSource.isEmpty {
            updatedSource = existingSource
        } else {
            updatedSource = "{\n}\n"
        }
        for edit in edits {
            if let value = edit.value {
                updatedSource = try sourceEditor.set(
                    path: edit.path.components,
                    value: JSONCPathEditor.EncodedValue(rawValue: value),
                    in: updatedSource
                )
            } else {
                updatedSource = try sourceEditor.remove(path: edit.path.components, in: updatedSource)
            }
        }
        let data = try sanitizer.encodedSource(updatedSource, preserving: document.originalData)

        // Validate our edited document before touching disk. This also gives
        // the cache the exact semantic root represented by the retained source;
        // comment-only empty parents can intentionally remain after reset.
        let sanitized = try sanitizer.sanitize(data)
        let object = try JSONSerialization.jsonObject(with: sanitized, options: [])
        guard let writtenRoot = object as? [String: Any] else {
            throw JSONConfigStoreReadError.notADictionary
        }
        if validateSemantics {
            try Self.validateGlobalCandidate(writtenRoot, baseline: document.root)
        }

        let parent = writeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        // The publisher performs the source-snapshot comparison as part of the
        // same atomic exchange that installs the candidate. A non-participating
        // editor that wins after our read is preserved and this mutation fails.
        guard Self.resolvedWriteURL(for: fileURL) == writeURL else {
            throw JSONConfigWriteConflict.sourceChanged
        }
        do {
            try publisher.publish(data, to: writeURL, expected: document.originalData)
        } catch {
            // A filesystem exchange can have happened before a later validation
            // error. Never keep serving a pre-publication cache after any
            // publisher failure; force the next read to observe disk and wake
            // subscribers so they converge on whichever entry won.
            cacheValid = false
            cachedRootResolvedPath = nil
            for continuation in subscribers.values {
                continuation.yield(())
            }
            throw error
        }

        // Only commit to cache after the file write succeeded.
        cachedRoot = writtenRoot
        cacheValid = true
        cachedRootResolvedPath = writeURL.path

        // Notify subscribers of our own write directly rather than relying on
        // the file watcher to observe an atomic rename.
        for continuation in subscribers.values {
            continuation.yield(())
        }
        return receipts
    }

    /// Rejects a complete candidate that has canonical global-schema issues
    /// the on-disk `baseline` doesn't already have.
    private static func validateGlobalCandidate(
        _ root: [String: Any],
        baseline: [String: Any]
    ) throws {
        let issues = CmuxConfigSemanticValidator(scope: .global)
            .issuesIntroduced(by: root, over: baseline)
        guard issues.isEmpty else {
            throw JSONConfigMutationError.invalidCandidate(issues)
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
