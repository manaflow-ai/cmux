import Foundation

/// Typed read/write/observe access to settings persisted in `UserDefaults`.
///
/// The store is an `actor`. Reads, writes, and reset are all `async`. There
/// are no locks; cross-thread access is serialized through actor isolation.
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
    public let underlyingDefaults: UserDefaults

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

    /// Returns the current value for the key.
    public func value<Value>(for key: DefaultsKey<Value>) -> Value {
        key.value(in: underlyingDefaults)
    }

    /// Writes a value for the key.
    public func set<Value>(_ value: Value, for key: DefaultsKey<Value>) {
        key.set(value, in: underlyingDefaults)
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
}
