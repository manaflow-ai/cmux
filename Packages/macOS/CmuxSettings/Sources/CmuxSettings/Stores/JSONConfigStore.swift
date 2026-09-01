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
/// on read via the injected ``JSONCSanitizer``. Writes round-trip through
/// `JSONSerialization` with sorted, pretty-printed output; comment-preserving
/// edits are a follow-up.
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
    private let pathResolver: JSONConfigFilePathResolver
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
        self.pathResolver = JSONConfigFilePathResolver()
        // The primary watcher observes the configured path, including symlink
        // replacement/retarget events in its parent directory. A secondary
        // target watcher observes edits that land in the resolved target's own
        // directory, which the configured-path watch cannot see.
        self.watcher = FileWatcher(path: fileURL.path)
        let resolved = pathResolver.resolvedURL(for: fileURL)
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

    /// Returns the stored value for the key, or `nil` when the path is absent
    /// or the value has the wrong JSON shape.
    ///
    /// Unlike ``value(for:)``, this preserves the distinction between an
    /// omitted/invalid entry and an explicitly stored value equal to the key's
    /// default. That distinction is useful for compatibility fallbacks and
    /// declarative settings whose effective value is derived from a legacy
    /// setting until the new key is authored.
    public func valueIfPresent<Value>(for key: JSONKey<Value>) -> Value? {
        let root = loadedRoot()
        return key.path.lookup(in: root).flatMap(Value.decodeFromJSON)
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

    /// Synchronously returns the stored value for `key`, or `nil` when the
    /// path is absent or invalid. This is the presence-preserving counterpart
    /// to ``snapshotValue(for:)`` for callers that cannot await.
    public nonisolated func snapshotValueIfPresent<Value>(for key: JSONKey<Value>) -> Value? {
        let root = (try? readFromDisk()) ?? [:]
        return key.path.lookup(in: root).flatMap(Value.decodeFromJSON)
    }

    /// Writes a value for the key.
    ///
    /// Creates the parent directory and the file if missing.
    ///
    /// - Throws: Errors from `FileManager` or `JSONSerialization` writing the file.
    public func set<Value>(_ value: Value, for key: JSONKey<Value>) throws {
        try mutateRoot { root in
            key.path.assign(value.encodeForJSON(), in: &root)
        }
    }

    /// Removes the key's entry from the file. Parent objects that become
    /// empty are pruned. The file itself is not deleted even when no entries
    /// remain.
    ///
    /// - Throws: Errors from `FileManager` or `JSONSerialization` writing the file.
    public func reset<Value>(_ key: JSONKey<Value>) throws {
        try mutateRoot { root in
            key.path.remove(in: &root)
        }
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
        makeValueStream { store in
            await store.value(for: key)
        }
    }

    /// Returns an `AsyncStream` that preserves whether a JSON value is
    /// present. The first element and every later element is either the
    /// decoded value or `nil` for an omitted/invalid entry.
    ///
    /// This is intentionally separate from ``values(for:)``: existing callers
    /// rely on that API's default-value semantics, while compatibility-aware
    /// consumers need to react when a dotfiles edit removes or invalidates a
    /// key. Values are deduplicated after decoding, and file-event bursts are
    /// coalesced exactly like the defaulting stream.
    public nonisolated func valuesIfPresent<Value>(for key: JSONKey<Value>) -> AsyncStream<Value?> {
        makeValueStream { store in
            await store.valueIfPresent(for: key)
        }
    }

    /// Returns one coherent JSON revision followed by each later file revision.
    ///
    /// Unlike independent key streams, a revision is decoded from one actor
    /// read of the complete root. Consumers that project several related keys
    /// can therefore publish one internally consistent snapshot per edit.
    public nonisolated func snapshots() -> AsyncStream<JSONConfigStoreSnapshot> {
        makeValueStream { store in
            await store.coherentSnapshot()
        }
    }

    // MARK: - Private

    /// Builds the shared subscription pipeline for both defaulting and
    /// presence-preserving streams. Registration precedes the initial read so
    /// writes cannot fall into a notification gap; the bounded signal stream
    /// coalesces bursts and typed equality suppresses duplicate values.
    private nonisolated func makeValueStream<Element: Equatable & Sendable>(
        read: @escaping @Sendable (JSONConfigStore) async -> Element
    ) -> AsyncStream<Element> {
        AsyncStream<Element>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                let id = UUID()
                let (signal, signalContinuation) = AsyncStream<Void>.makeStream(
                    bufferingPolicy: .bufferingNewest(1)
                )
                await self.addSubscriber(id: id, continuation: signalContinuation)
                let initial = await read(self)
                continuation.yield(initial)

                var last = initial
                for await _ in signal {
                    if Task.isCancelled { break }
                    let current = await read(self)
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

    /// Reads one coherent root while isolated to the store actor.
    public func coherentSnapshot() -> JSONConfigStoreSnapshot {
        let root = loadedRoot()
        let data = (try? JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
        return JSONConfigStoreSnapshot(data: data)
    }

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
        let resolved = pathResolver.resolvedURL(for: fileURL)
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
        let resolvedURL = pathResolver.resolvedURL(for: fileURL)
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
        try JSONConfigSnapshotDecoder(sanitizer: sanitizer).readRoot(at: url)
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
    private func mutateRoot(_ mutate: (inout [String: Any]) -> Void) throws {
        // Write through a symlink to its target rather than at the link path:
        // an atomic write is a temp-file + `rename()`, which would replace the
        // link itself with a regular file and break a dotfiles-managed config.
        let writeURL = pathResolver.resolvedURL(for: fileURL)
        var root = cacheIsCurrent(for: writeURL.path) ? cachedRoot : try readFromDisk(at: writeURL)
        mutate(&root)

        let parent = writeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: writeURL, options: [.atomic])

        // Only commit to cache after the file write succeeded.
        cachedRoot = root
        cacheValid = true
        cachedRootResolvedPath = writeURL.path

        // Notify subscribers of our own write directly rather than
        // relying on the file watcher to observe it. Atomic writes
        // replace the file via rename, which a vnode DispatchSource can
        // miss, so self-writes must be signalled here to guarantee the
        // `values(for:)` streams (and the view-models bound to them)
        // reflect a change made through this store. The cache is already
        // up to date, so subscribers re-read the new value immediately.
        for continuation in subscribers.values {
            continuation.yield(())
        }
    }
}
