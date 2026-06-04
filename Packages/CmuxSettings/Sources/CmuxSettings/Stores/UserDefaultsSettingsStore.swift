import Foundation

/// Typed read/write/observe access to settings persisted in `UserDefaults`.
///
/// The store is an `actor`. Reads, writes, and reset are all `async`. There
/// are no locks; cross-thread access is serialized through actor isolation.
///
/// The store only accepts ``DefaultsKey``; a ``JSONKey`` would be rejected at
/// compile time. There are no runtime store/key-mismatch traps.
///
/// Observation is driven by a single, store-owned block observer of
/// `UserDefaults.didChangeNotification`. The observer is bridged into a bounded
/// `AsyncStream<Void>` and fanned out to one bounded signal per active
/// ``values(for:)`` consumer; each consumer re-reads its typed value on a
/// signal and dedups. Cancelling a consumer's `Task` synchronously deregisters
/// its subscriber and ends its stream, so teardown never waits on a future
/// notification. This mirrors ``JSONConfigStore``'s subscriber fan-out and
/// avoids parking an uncancellable `Task` inside
/// `NotificationCenter.notifications(named:)` (the leak in issue #5329 / #5309).
///
/// ```swift
/// let catalog = SettingCatalog()
/// let store = UserDefaultsSettingsStore(
///     defaults: .standard,
///     migrating: catalog.all
/// )
/// await store.set(.dark, for: catalog.appAppearance)
/// for await mode in store.values(for: catalog.appAppearance) {
///     applyAppearance(mode)
/// }
/// ```
public actor UserDefaultsSettingsStore {
    /// The `UserDefaults` suite this store reads and writes.
    public let underlyingDefaults: UserDefaults

    /// Per-consumer change signals. One entry per live ``values(for:)`` stream;
    /// a single `UserDefaults` change fans out one `()` to each.
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// The block-observer registration, created lazily on the first subscriber.
    /// Releasing it (when this actor is deallocated) removes the observer.
    private var observerHandle: NotificationObserverHandle?

    /// The single long-lived task draining the bridged notification stream and
    /// fanning out to ``subscribers``. Created lazily with ``observerHandle``.
    private var observerTask: Task<Void, Never>?

    /// Creates a store backed by the given `UserDefaults` instance.
    ///
    /// Keys passed in ``migrating`` run their legacy-key migration
    /// synchronously inside init, before the actor is reachable. After init
    /// returns, migration is complete; no per-read migration state.
    ///
    /// - Parameters:
    ///   - defaults: The defaults suite. Pass a custom suite to isolate
    ///     reads/writes during tests.
    ///   - migrating: Catalog entries whose legacy keys should be migrated.
    ///     Pass ``SettingCatalog/all`` from the app, or an empty array when no
    ///     migration is needed.
    public init(defaults: UserDefaults, migrating: [AnySettingKey] = []) {
        self.underlyingDefaults = defaults
        // Each entry's migration closure was captured with its concrete
        // Value type, so it skips legacy keys whose stored value does not
        // decode as the new key's type. See AnySettingKey for details.
        for key in migrating {
            key.migrateUserDefaultsLegacyKeys(defaults)
        }
    }

    deinit {
        // The observer is removed by `observerHandle`'s own deinit via ARC; we
        // only stop the long-lived fan-out task here (Task is Sendable, so this
        // is legal from a nonisolated deinit).
        observerTask?.cancel()
    }

    /// Returns the current value for the key.
    public func value<Value>(for key: DefaultsKey<Value>) -> Value {
        let raw = underlyingDefaults.object(forKey: key.userDefaultsKey)
        return Value.decodeFromUserDefaults(raw) ?? key.defaultValue
    }

    /// Writes a value for the key.
    public func set<Value>(_ value: Value, for key: DefaultsKey<Value>) {
        underlyingDefaults.set(value.encodeForUserDefaults(), forKey: key.userDefaultsKey)
    }

    /// Removes the stored override for the key. After this call ``value(for:)``
    /// returns the key's default value until something writes a new override.
    public func reset<Value>(_ key: DefaultsKey<Value>) {
        underlyingDefaults.removeObject(forKey: key.userDefaultsKey)
    }

    /// Removes the stored overrides for every UserDefaults-backed entry in
    /// ``keys``. Entries whose ``AnySettingKey/kind`` is
    /// ``AnySettingKey/Kind/jsonConfig`` are ignored; reset them via the
    /// ``JSONConfigStore``.
    ///
    /// The whole operation runs inside the actor's isolation domain so
    /// the caller doesn't have to send the non-`Sendable` `UserDefaults`
    /// instance across boundaries.
    public func resetAll(_ keys: [AnySettingKey]) {
        for entry in keys {
            guard case let .userDefaults(storageKey, suite, _) = entry.kind else { continue }
            let defaults: UserDefaults
            if let suite, let custom = UserDefaults(suiteName: suite) {
                defaults = custom
            } else {
                defaults = underlyingDefaults
            }
            defaults.removeObject(forKey: storageKey)
        }
    }

    /// Returns an `AsyncStream` that yields the current value and every later change.
    ///
    /// - The first element is yielded as soon as the consumer starts iterating.
    /// - Subsequent elements are yielded when `UserDefaults.didChangeNotification`
    ///   fires and the typed value at this key differs from the previously
    ///   yielded value.
    /// - Cancelling the consuming `Task` cancels the underlying notification
    ///   loop and ends the stream.
    /// - Buffering is `.bufferingNewest(1)`: a burst of writes (e.g. a
    ///   `ColorPicker` drag spraying a value per frame) coalesces to the
    ///   most recent value rather than replaying every intermediate
    ///   through the consumer after the consumer catches up. Only the
    ///   latest value matters; the stale ones are dropped.
    public nonisolated func values<Value>(for key: DefaultsKey<Value>) -> AsyncStream<Value> {
        AsyncStream<Value>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                var lastYielded = await self.value(for: key)
                continuation.yield(lastYielded)

                let id = UUID()
                // bufferingNewest(1): the signal carries no payload, so a burst
                // of UserDefaults writes coalesces to a single wake; the typed
                // value is re-read and deduped below on each consumed signal.
                let (signal, signalContinuation) = AsyncStream<Void>.makeStream(
                    bufferingPolicy: .bufferingNewest(1)
                )
                await self.addSubscriber(id: id, continuation: signalContinuation)

                for await _ in signal {
                    if Task.isCancelled { break }
                    let current = await self.value(for: key)
                    if current != lastYielded {
                        lastYielded = current
                        continuation.yield(current)
                    }
                }
                await self.removeSubscriber(id: id)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Number of live ``values(for:)`` subscribers. Test seam: lets a test
    /// assert that consumer teardown deregisters its subscriber so observers do
    /// not accumulate across remounts (the #5329 / #5309 leak).
    var activeSubscriberCount: Int { subscribers.count }

    // MARK: - Private

    private func addSubscriber(id: UUID, continuation: AsyncStream<Void>.Continuation) {
        subscribers[id] = continuation
        ensureObserver()
    }

    private func removeSubscriber(id: UUID) {
        subscribers.removeValue(forKey: id)?.finish()
    }

    /// Registers the single block observer on the first subscribe. The observer
    /// is removed synchronously in `deinit`, so nothing is parked inside a
    /// non-cancellation-aware notification iterator.
    private func ensureObserver() {
        guard observerHandle == nil else { return }
        // bufferingNewest(1): the raw notification stream carries no payload;
        // bursts coalesce to one fan-out. Bounded buffering caps growth.
        let (rawSignal, rawContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        // Block-based observer (not NSObject KVO), bridged into a bounded
        // AsyncStream. The handle removes the observer when this actor is
        // released; callers never see NotificationCenter.
        observerHandle = NotificationObserverHandle(
            name: UserDefaults.didChangeNotification
        ) { _ in
            rawContinuation.yield(())
        }
        observerTask = Task { [weak self] in
            for await _ in rawSignal {
                guard let self else { break }
                await self.fanOutChange()
            }
        }
    }

    private func fanOutChange() {
        for continuation in subscribers.values {
            continuation.yield(())
        }
    }

}
