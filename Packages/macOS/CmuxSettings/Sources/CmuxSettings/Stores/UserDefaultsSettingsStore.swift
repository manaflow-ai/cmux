import Foundation
import Dispatch

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
/// let store = UserDefaultsSettingsStore(defaults: .standard)
/// await store.set(.dark, for: SettingCatalog().app.appearance)
/// ```
public actor UserDefaultsSettingsStore {
    /// The `UserDefaults` suite this store reads and writes.
    ///
    /// `UserDefaults` is Apple-documented thread-safe. Keep the non-Sendable
    /// instance inside a private unchecked-Sendable wrapper and expose only
    /// typed operations.
    private let storage: UserDefaultsSettingsStorage
    private let observedMutationWatermarks = UserDefaultsSettingsObservedMutationWatermarks()
    private var mutationSources: [String: UserDefaultsSettingsMutationSourceRecord] = [:]
    private var supersededMutationSources: [
        String: [(source: UserDefaultsSettingsMutationSource, sequence: UInt64)]
    ] = [:]
    private var acceptedMutationLogicalOrders: [String: UInt64] = [:]
    private var acceptedMutationSources: [String: UserDefaultsSettingsMutationSource] = [:]
    private var knownValues: [String: any Sendable] = [:]
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
        guard shouldAcceptMutationSource(source, for: key) else {
            return nil
        }
        recordAcceptedMutation(source, for: key.userDefaultsKey)
        recordMutationSource(source, value: value, for: key.userDefaultsKey)
        if let source {
            observedMutationWatermarks.beginMutationSource(source, for: key.userDefaultsKey)
        }
        storage.set(value, for: key)
        if let source {
            observedMutationWatermarks.endMutationSource(source, for: key.userDefaultsKey)
        }
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
        guard shouldAcceptMutationSource(source, for: key) else {
            return nil
        }
        recordAcceptedMutation(source, for: key.userDefaultsKey)
        recordMutationSource(source, value: key.defaultValue, for: key.userDefaultsKey)
        if let source {
            observedMutationWatermarks.beginMutationSource(source, for: key.userDefaultsKey)
        }
        storage.removeObject(forKey: key.userDefaultsKey)
        if let source {
            observedMutationWatermarks.endMutationSource(source, for: key.userDefaultsKey)
        }
        return source
    }

    /// Removes stored overrides for every UserDefaults-backed entry in ``keys``.
    ///
    /// JSON-config entries are ignored; reset them via ``JSONConfigStore``.
    public func resetAll(_ keys: [AnySettingKey]) {
        for entry in keys {
            guard case let .userDefaults(storageKey, suite, _) = entry.kind else { continue }
            recordSourceLessMutation(for: storageKey)
            knownValues.removeValue(forKey: storageKey)
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
            recordKnownValue(value, for: storageKey)
        } else {
            recordKnownValue(value, for: storageKey)
            recordSourceLessMutation(for: storageKey, recordsAcceptedMutation: false)
        }
    }

    private func recordSourceLessMutation(
        for storageKey: String,
        recordsAcceptedMutation: Bool = true
    ) {
        if recordsAcceptedMutation {
            recordAcceptedMutation(nil, for: storageKey)
        }
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

    private func shouldAcceptMutationSource<Value: SettingCodable>(
        _ source: UserDefaultsSettingsMutationSource?,
        for key: DefaultsKey<Value>
    ) -> Bool {
        guard let source else { return true }
        let storageKey = key.userDefaultsKey

        if let acceptedOrder = acceptedMutationLogicalOrders[storageKey],
           source.logicalOrder < acceptedOrder {
            return false
        }
        if let acceptedSource = acceptedMutationSources[storageKey],
           source.ownerID == acceptedSource.ownerID,
           source.logicalOrder == acceptedSource.logicalOrder,
           source.sequence < acceptedSource.sequence {
            return false
        }

        if let notificationOrder = observedMutationWatermarks.latestNotificationLogicalOrder(for: storageKey),
           source.logicalOrder < notificationOrder {
            let currentValue = storage.value(for: key)
            let isKnownValue = knownValue(currentValue, matchesValueFor: storageKey)
            let isPendingSourceValue = mutationSources[storageKey]?.matches(currentValue) == true
            if !isKnownValue && !isPendingSourceValue {
                recordKnownValue(currentValue, for: storageKey)
                recordAcceptedMutation(nil, logicalOrder: notificationOrder, for: storageKey)
                return false
            }
        }

        return true
    }

    private func recordKnownValue<Value: SettingCodable>(_ value: Value, for storageKey: String) {
        knownValues[storageKey] = value
    }

    private func recordSourceLessObservedMutation<Value: SettingCodable>(value: Value, logicalOrder: UInt64, for storageKey: String) {
        recordAcceptedMutation(nil, logicalOrder: logicalOrder, for: storageKey)
        recordKnownValue(value, for: storageKey)
    }

    private func knownValue<Value: SettingCodable>(
        _ value: Value,
        matchesValueFor storageKey: String
    ) -> Bool {
        guard let knownValue = knownValues[storageKey] as? Value else { return false }
        return knownValue == value
    }

    private func recordAcceptedMutation(
        _ source: UserDefaultsSettingsMutationSource?,
        logicalOrder sourceLessLogicalOrder: UInt64? = nil,
        for storageKey: String
    ) {
        let logicalOrder = source?.logicalOrder
            ?? sourceLessLogicalOrder
            ?? DispatchTime.now().uptimeNanoseconds
        acceptedMutationLogicalOrders[storageKey] = max(
            acceptedMutationLogicalOrders[storageKey] ?? 0,
            logicalOrder
        )
        if let source {
            acceptedMutationSources[storageKey] = source
        } else {
            acceptedMutationSources.removeValue(forKey: storageKey)
        }
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
        deliveredMutationSource: UserDefaultsSettingsMutationSource? = nil,
        deliverPendingMutationSourceWhenUnobserved: Bool = false,
        supersedesPendingMutationSource: Bool = false,
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
                if includedMutationSources.contains(record.source)
                    || deliveredMutationSource == record.source
                    || (deliverPendingMutationSourceWhenUnobserved
                        && !supersedesPendingMutationSource) {
                    source = record.source
                } else {
                    supersededSource = record.source
                }
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
                selectedSupersededSource = record.source
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

    /// Returns a coalescing stream of the current value and later changes.
    ///
    /// Cancelling the consumer removes the observer and drain task. Bursts use
    /// `.bufferingNewest(1)` because only the latest settings value matters.
    public nonisolated func values<Value>(for key: DefaultsKey<Value>) -> AsyncStream<Value> {
        let storage = self.storage
        return AsyncStream<Value>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let (signals, signalContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

            let observer = storage.addDidChangeObserver { [weak self] _ in
                guard self != nil else { return }
                signalContinuation.yield(())
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
    /// Callers use sources to distinguish their async store echoes from
    /// external changes. `includedMutationSources` classifies pending writes
    /// that reached the store before stream creation.
    public func valueEvents<Value>(
        for key: DefaultsKey<Value>,
        includingSources includedMutationSources: Set<UserDefaultsSettingsMutationSource> = []
    ) -> AsyncStream<UserDefaultsSettingsValueEvent<Value>> {
        let initialConsumedSourceSequence = mutationSourceSequences[key.userDefaultsKey] ?? 0
        let storage = self.storage
        let observedMutationWatermarks = self.observedMutationWatermarks
        let storageKey = key.userDefaultsKey
        let streamStartLogicalOrder = DispatchTime.now().uptimeNanoseconds
        recordKnownValue(storage.value(for: key), for: storageKey)
        return AsyncStream<UserDefaultsSettingsValueEvent<Value>>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            typealias Signal = (isBackingDefaultsNotification: Bool, logicalOrder: UInt64, deliveredMutationSource: UserDefaultsSettingsMutationSource?)
            let (signals, signalContinuation) = AsyncStream<Signal>.makeStream(bufferingPolicy: .bufferingNewest(1))

            let observer = storage.addDidChangeObserver { [weak self] isBackingDefaultsNotification in
                guard self != nil else { return }
                let logicalOrder = DispatchTime.now().uptimeNanoseconds
                let deliveredMutationSource = observedMutationWatermarks.recordNotification(
                    logicalOrder: logicalOrder,
                    isBackingDefaultsNotification: isBackingDefaultsNotification,
                    for: storageKey
                )
                signalContinuation.yield((
                    isBackingDefaultsNotification,
                    logicalOrder,
                    deliveredMutationSource
                ))
            }

            let drainTask = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                var consumedSourceSequence = initialConsumedSourceSequence
                let initialBackingNotification = observedMutationWatermarks.latestBackingNotification(
                    after: streamStartLogicalOrder,
                    for: storageKey
                )
                let initialSnapshot = await self.valueEvent(
                    for: key,
                    consumedSourceSequence: consumedSourceSequence,
                    includedMutationSources: includedMutationSources,
                    deliveredMutationSource: initialBackingNotification?.mutationSource,
                    deliverPendingMutationSourceWhenUnobserved: initialBackingNotification == nil,
                    supersedesPendingMutationSource: initialBackingNotification != nil
                        && initialBackingNotification?.mutationSource == nil,
                    isInitialSnapshot: true
                )
                consumedSourceSequence = initialSnapshot.consumedSourceSequence
                var lastYieldedEvent = initialSnapshot.event
                if initialSnapshot.event.mutationSource == nil,
                   initialSnapshot.event.supersededMutationSource != nil {
                    await self.recordAcceptedMutation(
                        nil,
                        logicalOrder: DispatchTime.now().uptimeNanoseconds,
                        for: key.userDefaultsKey
                    )
                }
                continuation.yieldPreservingSources(initialSnapshot.event)

                for await signal in signals {
                    if Task.isCancelled { break }
                    let snapshot = await self.valueEvent(
                        for: key,
                        consumedSourceSequence: consumedSourceSequence,
                        deliveredMutationSource: signal.deliveredMutationSource,
                        supersedesPendingMutationSource: signal.deliveredMutationSource == nil
                    )
                    consumedSourceSequence = snapshot.consumedSourceSequence
                    var currentEvent = snapshot.event
                    if signal.deliveredMutationSource == nil,
                       currentEvent.value == lastYieldedEvent.value,
                       currentEvent.mutationSource == nil,
                       currentEvent.supersededMutationSource == nil,
                       let supersededSource = lastYieldedEvent.deliveryMutationSource {
                        currentEvent = UserDefaultsSettingsValueEvent(
                            value: currentEvent.value,
                            supersededMutationSource: supersededSource
                        )
                    }
                    if currentEvent.mutationSource == nil,
                       (currentEvent.value != lastYieldedEvent.value
                        || currentEvent.supersededMutationSource != nil) {
                        await self.recordSourceLessObservedMutation(
                            value: currentEvent.value,
                            logicalOrder: signal.logicalOrder,
                            for: key.userDefaultsKey
                        )
                    } else if currentEvent.value != lastYieldedEvent.value {
                        await self.recordKnownValue(currentEvent.value, for: key.userDefaultsKey)
                    }
                    if !signal.isBackingDefaultsNotification {
                        guard currentEvent.value != lastYieldedEvent.value
                            || currentEvent.mutationSource != nil
                            || currentEvent.supersededMutationSource != nil
                        else { continue }
                    }
                    if currentEvent.value != lastYieldedEvent.value
                        || currentEvent.mutationSource != nil
                        || currentEvent.supersededMutationSource != nil {
                        lastYieldedEvent = currentEvent
                        continuation.yieldPreservingSources(currentEvent)
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
