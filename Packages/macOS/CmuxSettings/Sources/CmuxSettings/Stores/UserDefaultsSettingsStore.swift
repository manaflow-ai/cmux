import Foundation

/// Typed read/write/observe access to settings persisted in `UserDefaults`.
///
/// The store is an `actor`. Reads, writes, reset, and source-tagged
/// observation setup all run through actor isolation.
///
/// The store only accepts ``DefaultsKey``; a ``JSONKey`` would be rejected at
/// compile time. There are no runtime store/key-mismatch traps.
///
/// Observation ignores unrelated `UserDefaults` notifications unless the
/// observed key's value changed, and feeds a bounded signal into one cancellable
/// drain task per ``values(for:)`` consumer. The observer token is removed and
/// the drain task is cancelled when the stream terminates, without a permanently
/// parked NotificationCenter async-sequence task or per-notification task
/// fan-out.
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
    private var mutationSources: [String: UserDefaultsSettingsMutationSourceRecord] = [:]
    private var supersededMutationSources: [
        String: [(source: UserDefaultsSettingsMutationSource, sequence: UInt64)]
    ] = [:]
    private var acceptedMutationLogicalOrders: [String: UInt64] = [:]
    private var acceptedMutationSourceSequences: [String: [UUID: UInt64]] = [:]
    private var mutationSourceSequences: [String: UInt64] = [:]
    private let maximumSupersededMutationSourcesPerKey = 64

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
    ///
    /// If `source` is older than a logical write that this key has already
    /// accepted, the stale write is ignored and `nil` is returned.
    @discardableResult
    public func set<Value>(
        _ value: Value,
        for key: DefaultsKey<Value>,
        source: UserDefaultsSettingsMutationSource? = nil
    ) -> UserDefaultsSettingsMutationSource? {
        guard shouldAcceptMutationSource(source, for: key.userDefaultsKey) else {
            return nil
        }
        recordAcceptedMutation(source, for: key.userDefaultsKey)
        recordMutationSource(source, value: value, for: key.userDefaultsKey)
        storage.set(value, for: key)
        return source
    }

    /// Removes the stored override for the key. After this call ``value(for:)``
    /// returns the key's default value until something writes a new override.
    ///
    /// If `source` is older than a logical write that this key has already
    /// accepted, the stale reset is ignored and `nil` is returned.
    @discardableResult
    public func reset<Value>(
        _ key: DefaultsKey<Value>,
        source: UserDefaultsSettingsMutationSource? = nil
    ) -> UserDefaultsSettingsMutationSource? {
        guard shouldAcceptMutationSource(source, for: key.userDefaultsKey) else {
            return nil
        }
        recordAcceptedMutation(source, for: key.userDefaultsKey)
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
            if let record = mutationSources[storageKey] {
                recordSupersededMutationSource(
                    record.source,
                    sequence: sequence,
                    for: storageKey
                )
            }
            mutationSources[storageKey] = UserDefaultsSettingsMutationSourceRecord(
                source: source,
                sequence: sequence,
                value: value
            )
        } else {
            if let record = mutationSources[storageKey] {
                let sequence = nextMutationSourceSequence(for: storageKey)
                recordSupersededMutationSource(
                    record.source,
                    sequence: sequence,
                    for: storageKey
                )
            }
            mutationSources.removeValue(forKey: storageKey)
        }
    }

    private func shouldAcceptMutationSource(
        _ source: UserDefaultsSettingsMutationSource?,
        for storageKey: String
    ) -> Bool {
        guard let source else { return true }

        if let acceptedOrder = acceptedMutationLogicalOrders[storageKey],
           source.logicalOrder <= acceptedOrder {
            return false
        }

        guard let acceptedSequence = acceptedMutationSourceSequences[storageKey]?[source.ownerID] else {
            return true
        }

        return source.sequence > acceptedSequence
    }

    private func recordAcceptedMutation(
        _ source: UserDefaultsSettingsMutationSource?,
        for storageKey: String
    ) {
        let logicalOrder = source?.logicalOrder ?? UserDefaultsSettingsMutationSource.nextLogicalOrder()
        acceptedMutationLogicalOrders[storageKey] = max(
            acceptedMutationLogicalOrders[storageKey] ?? 0,
            logicalOrder
        )

        guard let source else { return }

        var ownerSequences = acceptedMutationSourceSequences[storageKey] ?? [:]
        if let acceptedSequence = ownerSequences[source.ownerID] {
            ownerSequences[source.ownerID] = max(acceptedSequence, source.sequence)
        } else {
            ownerSequences[source.ownerID] = source.sequence
        }
        acceptedMutationSourceSequences[storageKey] = ownerSequences
    }

    private func recordSupersededMutationSource(
        _ source: UserDefaultsSettingsMutationSource,
        sequence: UInt64,
        for storageKey: String
    ) {
        var sources = supersededMutationSources[storageKey] ?? []
        if !sources.contains(where: { $0.source == source }) {
            sources.append((source, sequence))
        }
        let overflow = sources.count - maximumSupersededMutationSourcesPerKey
        if overflow > 0 {
            sources.removeFirst(overflow)
        }
        supersededMutationSources[storageKey] = sources
    }

    private func nextMutationSourceSequence(for storageKey: String) -> UInt64 {
        let nextSequence = (mutationSourceSequences[storageKey] ?? 0) &+ 1
        mutationSourceSequences[storageKey] = nextSequence
        return nextSequence
    }

    private func valueEvent<Value>(
        for key: DefaultsKey<Value>,
        consumedSourceSequence: UInt64,
        includedMutationSources: Set<UserDefaultsSettingsMutationSource> = [],
        isInitialSnapshot: Bool = false
    ) -> (
        event: UserDefaultsSettingsValueEvent<Value>,
        consumedSourceSequence: UInt64
    ) {
        let value = storage.value(for: key)
        var nextConsumedSourceSequence = consumedSourceSequence
        var source: UserDefaultsSettingsMutationSource?
        var supersededSource: UserDefaultsSettingsMutationSource?
        if let record = mutationSources[key.userDefaultsKey],
           record.sequence > consumedSourceSequence || includedMutationSources.contains(record.source) {
            nextConsumedSourceSequence = max(record.sequence, consumedSourceSequence)
            if record.matches(value) {
                source = record.source
            } else {
                supersededSource = record.source
            }
        }
        if source == nil,
           let storedSupersededSources = supersededMutationSources[key.userDefaultsKey] {
            var selectedSupersededSource: UserDefaultsSettingsMutationSource?
            for record in storedSupersededSources {
                let shouldDeliver = record.sequence > consumedSourceSequence
                    || includedMutationSources.contains(record.source)
                guard shouldDeliver else { continue }
                nextConsumedSourceSequence = max(record.sequence, nextConsumedSourceSequence)
                if selectedSupersededSource == nil || includedMutationSources.contains(record.source) {
                    selectedSupersededSource = record.source
                }
            }
            supersededSource = supersededSource ?? selectedSupersededSource
        }

        return (
            UserDefaultsSettingsValueEvent(
                value: value,
                mutationSource: source,
                supersededMutationSource: supersededSource,
                isInitialSnapshot: isInitialSnapshot
            ),
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
        let storage = self.storage
        return AsyncStream<Value>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let (signals, signalContinuation) = AsyncStream<Bool>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )

            let observer = storage.addDidChangeObserver { [weak self] isBackingDefaultsNotification in
                guard self != nil else { return }
                signalContinuation.yield(isBackingDefaultsNotification)
            }

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
    ///
    /// - Parameter includedMutationSources: Caller-owned pending sources to
    ///   classify even if their writes reached the store before this stream was
    ///   created.
    public func valueEvents<Value>(
        for key: DefaultsKey<Value>,
        includingSources includedMutationSources: Set<UserDefaultsSettingsMutationSource> = []
    ) -> AsyncStream<UserDefaultsSettingsValueEvent<Value>> {
        let initialConsumedSourceSequence = mutationSourceSequences[key.userDefaultsKey] ?? 0
        let storage = self.storage
        return AsyncStream<UserDefaultsSettingsValueEvent<Value>>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let (signals, signalContinuation) = AsyncStream<Bool>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )

            let observer = storage.addDidChangeObserver { [weak self] isBackingDefaultsNotification in
                guard self != nil else { return }
                signalContinuation.yield(isBackingDefaultsNotification)
            }

            let drainTask = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                var consumedSourceSequence = initialConsumedSourceSequence
                let initialSnapshot = await self.valueEvent(
                    for: key,
                    consumedSourceSequence: consumedSourceSequence,
                    includedMutationSources: includedMutationSources,
                    isInitialSnapshot: true
                )
                consumedSourceSequence = initialSnapshot.consumedSourceSequence
                var lastYieldedEvent = initialSnapshot.event
                continuation.yield(initialSnapshot.event)

                for await isBackingDefaultsNotification in signals {
                    if Task.isCancelled { break }
                    if !isBackingDefaultsNotification {
                        let current = await self.value(for: key)
                        guard current != lastYieldedEvent.value else { continue }
                    }
                    let snapshot = await self.valueEvent(
                        for: key,
                        consumedSourceSequence: consumedSourceSequence
                    )
                    consumedSourceSequence = snapshot.consumedSourceSequence
                    let currentEvent = snapshot.event
                    if currentEvent.value != lastYieldedEvent.value
                        || currentEvent.mutationSource != nil
                        || currentEvent.supersededMutationSource != nil {
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
