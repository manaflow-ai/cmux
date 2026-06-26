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
/// Observation uses a single ``CmuxFileWatch/FileWatcher`` owned by the store
/// and fans out file-change events to per-subscriber `AsyncStream<Void>`
/// signals. One file event causes exactly one cache invalidation and one
/// notification per active subscriber, regardless of how many keys are being
/// observed. Each subscriber dedups on its own typed value so only real
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
    private let watcher: FileWatcher

    private var cachedRoot: [String: Any] = [:]
    private var cacheValid = false
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var watcherTask: Task<Void, Never>?

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
        self.watcher = FileWatcher(path: fileURL.path)
    }

    deinit {
        watcherTask?.cancel()
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

    /// Sets or removes a single entry in a string-keyed map at `key`, preserving
    /// every *other* entry's raw on-disk form.
    ///
    /// Unlike ``set(_:for:)`` — which replaces the whole map with a typed,
    /// re-encoded value and therefore drops any sibling this process cannot
    /// decode (e.g. a shortcut written in string form `"cmd+n"` when the typed
    /// value is the object form) — this reads the map as raw JSON, mutates only
    /// `entryKey`, and writes it back. Pass `rawValue: nil` to remove the entry.
    /// The map (and its parents) are pruned when the last entry is removed.
    ///
    /// - Throws: Errors from `FileManager` or `JSONSerialization` writing the file.
    public func setMapEntry<Value>(
        _ rawValue: Any?,
        forKey entryKey: String,
        in key: JSONKey<[String: Value]>
    ) throws {
        try mutateRoot { root in
            var map = (key.path.lookup(in: root) as? [String: Any]) ?? [:]
            if let rawValue {
                map[entryKey] = rawValue
            } else {
                map.removeValue(forKey: entryKey)
            }
            if map.isEmpty {
                key.path.remove(in: &root)
            } else {
                key.path.assign(map, in: &root)
            }
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

    /// Spawns the watcher-consumer task on the first subscribe. The task
    /// drains the ``CmuxFileWatch/FileWatcher`` events and fans out to every
    /// registered subscriber after invalidating the cache.
    private func ensureWatcherTask() {
        guard watcherTask == nil else { return }
        let watcher = self.watcher
        watcherTask = Task { [weak self] in
            for await _ in watcher.events {
                if Task.isCancelled { break }
                guard let self else { break }
                await self.handleFileChange()
            }
        }
    }

    private func handleFileChange() {
        cacheValid = false
        for continuation in subscribers.values {
            continuation.yield(())
        }
    }

    private func loadedRoot() -> [String: Any] {
        if cacheValid { return cachedRoot }
        cachedRoot = (try? readFromDisk()) ?? [:]
        cacheValid = true
        return cachedRoot
    }

    /// Reads and decodes the config root from disk. A missing or empty file
    /// decodes to an empty root; a present-but-unparseable file throws so
    /// callers can refuse to overwrite it. `nonisolated` so the synchronous
    /// ``snapshotValue(for:)`` can call it without hopping onto the actor; it
    /// only touches the `nonisolated` `fileURL` and the `Sendable` `sanitizer`.
    private nonisolated func readFromDisk() throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return [:]
        }
        if data.isEmpty { return [:] }
        let sanitized = try sanitizer.sanitize(data)
        let object = try JSONSerialization.jsonObject(with: sanitized, options: [])
        guard let dictionary = object as? [String: Any] else {
            throw JSONConfigStoreReadError.notADictionary
        }
        return dictionary
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
    /// ``readFromDisk()`` is propagated to the caller.
    private func mutateRoot(_ mutate: (inout [String: Any]) -> Void) throws {
        var root = cacheValid ? cachedRoot : try readFromDisk()
        mutate(&root)

        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: fileURL, options: [.atomic])

        // Only commit to cache after the file write succeeded.
        cachedRoot = root
        cacheValid = true

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
