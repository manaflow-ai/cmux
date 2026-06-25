import Foundation

// Safe to share across tasks: this narrow mirror stores only monotonic per-key
// sequence baselines, protects all mutable state with `lock`, and does no async
// work or user-callback invocation while the lock is held.
private final class UserDefaultsSettingsMutationSourceSequenceMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var sequences: [String: UInt64] = [:]

    func sequence(for storageKey: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return sequences[storageKey] ?? 0
    }

    func store(_ sequence: UInt64, for storageKey: String) {
        lock.lock()
        sequences[storageKey] = sequence
        lock.unlock()
    }
}

/// Typed read/write/observe access to settings persisted in `UserDefaults`.
///
/// The store is an `actor`. Reads, writes, and reset are all `async`. There
/// is one narrow nonisolated lock for stream-baseline sequence snapshots; all
/// storage access remains serialized through actor isolation.
///
/// The store only accepts ``DefaultsKey``; a ``JSONKey`` would be rejected at
/// compile time. There are no runtime store/key-mismatch traps.
///
/// Observation uses `NotificationCenter.addObserver(forName:object:queue:using:)`
/// to feed a bounded signal into one cancellable drain task per
/// ``values(for:)`` consumer. The observer token is removed and the drain task
/// is cancelled when the stream terminates, without a permanently parked
/// NotificationCenter async-sequence task or per-notification task fan-out.
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
    ///
    /// `UserDefaults` is Apple-documented thread-safe. Keep the non-Sendable
    /// instance inside a private unchecked-Sendable wrapper and expose only
    /// typed operations.
    private let storage: UserDefaultsSettingsStorage
    private nonisolated let mutationSourceSequenceMirror = UserDefaultsSettingsMutationSourceSequenceMirror()
    private var mutationSources: [String: UserDefaultsSettingsMutationSourceRecord] = [:]
    private var mutationSourceSequences: [String: UInt64] = [:]

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
        self.storage = UserDefaultsSettingsStorage(defaults: defaults)
        // Each entry's migration closure was captured with its concrete
        // Value type, so it skips legacy keys whose stored value does not
        // decode as the new key's type. See AnySettingKey for details.
        for key in migrating {
            key.migrateUserDefaultsLegacyKeys(defaults)
        }
    }

    /// Returns the current value for the key.
    public func value<Value>(for key: DefaultsKey<Value>) -> Value {
        storage.value(for: key)
    }

    /// Synchronously seeds UI state from the backing `UserDefaults` suite.
    ///
    /// Settings views need a value during SwiftUI construction before they can
    /// await the actor. This keeps the non-Sendable `UserDefaults` instance
    /// inside the store while returning only the typed setting value.
    public nonisolated func initialValue<Value>(for key: DefaultsKey<Value>) -> Value {
        storage.value(for: key)
    }

    /// Writes a value for the key.
    @discardableResult
    public func set<Value>(
        _ value: Value,
        for key: DefaultsKey<Value>,
        source: UserDefaultsSettingsMutationSource? = nil
    ) -> UserDefaultsSettingsMutationSource? {
        recordMutationSource(source, value: value, for: key.userDefaultsKey)
        storage.set(value, for: key)
        return source
    }

    /// Removes the stored override for the key. After this call ``value(for:)``
    /// returns the key's default value until something writes a new override.
    @discardableResult
    public func reset<Value>(
        _ key: DefaultsKey<Value>,
        source: UserDefaultsSettingsMutationSource? = nil
    ) -> UserDefaultsSettingsMutationSource? {
        recordMutationSource(source, value: key.defaultValue, for: key.userDefaultsKey)
        storage.removeObject(forKey: key.userDefaultsKey)
        return source
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
                storage.removeObject(forKey: storageKey)
                continue
            }
            defaults.removeObject(forKey: storageKey)
        }
    }

    private func recordMutationSource<Value: SettingCodable>(
        _ source: UserDefaultsSettingsMutationSource?,
        value: Value,
        for storageKey: String
    ) {
        if let source {
            let sequence = nextMutationSourceSequence(for: storageKey)
            mutationSources[storageKey] = UserDefaultsSettingsMutationSourceRecord(
                source: source,
                sequence: sequence,
                value: value
            )
        } else {
            mutationSources.removeValue(forKey: storageKey)
        }
    }

    private func nextMutationSourceSequence(for storageKey: String) -> UInt64 {
        let nextSequence = (mutationSourceSequences[storageKey] ?? 0) &+ 1
        mutationSourceSequences[storageKey] = nextSequence
        mutationSourceSequenceMirror.store(nextSequence, for: storageKey)
        return nextSequence
    }

    private func valueEvent<Value>(
        for key: DefaultsKey<Value>,
        consumedSourceSequence: UInt64
    ) -> (
        event: UserDefaultsSettingsValueEvent<Value>,
        consumedSourceSequence: UInt64
    ) {
        let value = storage.value(for: key)
        var nextConsumedSourceSequence = consumedSourceSequence
        var source: UserDefaultsSettingsMutationSource?
        if let record = mutationSources[key.userDefaultsKey],
           record.sequence > consumedSourceSequence {
            nextConsumedSourceSequence = record.sequence
            if record.matches(value) {
                source = record.source
            }
        }

        return (
            UserDefaultsSettingsValueEvent(value: value, mutationSource: source),
            nextConsumedSourceSequence
        )
    }

    /// Returns an `AsyncStream` that yields the current value and every later change.
    ///
    /// - The first element is yielded as soon as the consumer starts iterating.
    /// - Subsequent elements are yielded when `UserDefaults.didChangeNotification`
    ///   fires and the typed value at this key differs from the previously
    ///   yielded value, or when a store-owned mutation source needs delivery.
    /// - Cancelling the consuming `Task` removes the underlying notification
    ///   observer, cancels the drain task, and ends the stream.
    /// - Buffering is `.bufferingNewest(1)`: a burst of writes (e.g. a
    ///   `ColorPicker` drag spraying a value per frame) coalesces to the
    ///   most recent value rather than replaying every intermediate
    ///   through the consumer after the consumer catches up. Only the
    ///   latest value matters; the stale ones are dropped.
    public nonisolated func values<Value>(for key: DefaultsKey<Value>) -> AsyncStream<Value> {
        AsyncStream<Value>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let (signals, signalContinuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )

            let observer = NotificationObserverToken(
                NotificationCenter.default.addObserver(
                    forName: UserDefaults.didChangeNotification,
                    object: nil,
                    queue: nil
                ) { [weak self] _ in
                    guard self != nil else { return }
                    signalContinuation.yield(())
                }
            )

            let drainTask = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                var lastYielded = await self.value(for: key)
                continuation.yield(lastYielded)

                for await _ in signals {
                    if Task.isCancelled { break }
                    let current = await self.value(for: key)
                    if current != lastYielded {
                        lastYielded = current
                        continuation.yield(current)
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                drainTask.cancel()
                signalContinuation.finish()
                observer.remove()
            }
        }
    }

    /// Returns value changes tagged with one-shot store-owned mutation sources.
    ///
    /// The source is present only on the observed value produced by a write
    /// that explicitly passed one to ``set(_:for:source:)`` or
    /// ``reset(_:source:)``. Callers use it to distinguish their own async
    /// store echoes from external settings changes without relying on lossy
    /// value equality.
    public nonisolated func valueEvents<Value>(
        for key: DefaultsKey<Value>
    ) -> AsyncStream<UserDefaultsSettingsValueEvent<Value>> {
        AsyncStream<UserDefaultsSettingsValueEvent<Value>>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let initialConsumedSourceSequence = mutationSourceSequenceMirror.sequence(
                for: key.userDefaultsKey
            )
            let (signals, signalContinuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )

            let observer = NotificationObserverToken(
                NotificationCenter.default.addObserver(
                    forName: UserDefaults.didChangeNotification,
                    object: nil,
                    queue: nil
                ) { [weak self] _ in
                    guard self != nil else { return }
                    signalContinuation.yield(())
                }
            )

            let drainTask = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                var consumedSourceSequence = initialConsumedSourceSequence
                let initialSnapshot = await self.valueEvent(
                    for: key,
                    consumedSourceSequence: consumedSourceSequence
                )
                consumedSourceSequence = initialSnapshot.consumedSourceSequence
                var lastYieldedEvent = initialSnapshot.event
                continuation.yield(initialSnapshot.event)

                for await _ in signals {
                    if Task.isCancelled { break }
                    let snapshot = await self.valueEvent(
                        for: key,
                        consumedSourceSequence: consumedSourceSequence
                    )
                    consumedSourceSequence = snapshot.consumedSourceSequence
                    let currentEvent = snapshot.event
                    if currentEvent.value != lastYieldedEvent.value || currentEvent.mutationSource != nil {
                        lastYieldedEvent = currentEvent
                        continuation.yield(currentEvent)
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                drainTask.cancel()
                signalContinuation.finish()
                observer.remove()
            }
        }
    }
}
