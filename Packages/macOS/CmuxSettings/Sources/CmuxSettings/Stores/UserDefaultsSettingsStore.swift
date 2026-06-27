import Foundation
import Dispatch

/// Typed read/write/observe access to settings persisted in `UserDefaults`.
///
/// ```swift
/// let store = UserDefaultsSettingsStore(defaults: .standard)
/// await store.set(.dark, for: SettingCatalog().app.appearance)
/// ```
public actor UserDefaultsSettingsStore {
    /// The `UserDefaults` suite this store reads and writes.
    private let storage: UserDefaultsSettingsStorage
    private let observedMutationWatermarks = UserDefaultsSettingsObservedMutationWatermarks()
    private var mutationSources: [String: UserDefaultsSettingsMutationSourceRecord] = [:]
    private var supersededMutationSources: [
        String: [(source: UserDefaultsSettingsMutationSource, sequence: UInt64)]
    ] = [:]
    private var acceptedMutationLogicalOrders: [String: UInt64] = [:]
    private var acceptedMutationSourcesByOwner: [String: [UUID: UserDefaultsSettingsMutationSource]] = [:]
    private var knownValues: [String: any Sendable] = [:]
    private var knownValueLogicalOrders: [String: UInt64] = [:]
    private var mutationSourceSequences: [String: UInt64] = [:]
    private let maximumSupersededMutationSourcesPerKey = 64

    /// Creates a store backed by the given `UserDefaults` instance.
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

    /// Removes the stored override for the key.
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
    public func resetAll(_ keys: [AnySettingKey]) {
        for entry in keys {
            guard case let .userDefaults(storageKey, suite, _) = entry.kind else { continue }
            recordSourceLessMutation(for: storageKey)
            knownValues[storageKey] = entry.userDefaultsDefaultValue
            knownValueLogicalOrders[storageKey] = DispatchTime.now().uptimeNanoseconds
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
                recordSupersededMutationSource(record.source, sequence: sequence, for: storageKey)
            }
            mutationSources[storageKey] = UserDefaultsSettingsMutationSourceRecord(
                source: source,
                sequence: sequence,
                value: value
            )
            recordKnownValue(value, logicalOrder: source.logicalOrder, for: storageKey)
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
            recordSupersededMutationSource(record.source, sequence: sequence, for: storageKey)
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
        if let acceptedSource = acceptedMutationSourcesByOwner[storageKey]?[source.ownerID],
           source.logicalOrder == acceptedSource.logicalOrder,
           source.sequence < acceptedSource.sequence {
            return false
        }

        if let notificationOrder = observedMutationWatermarks.latestNotificationLogicalOrder(for: storageKey),
           source.logicalOrder < notificationOrder {
            let currentValue = storage.value(for: key)
            let isKnownValue = knownValue(currentValue, matchesValueFor: storageKey)
            let isPendingSourceValue = mutationSources[storageKey]?.matches(currentValue) == true
            let sourcePredatesKnownValue = source.logicalOrder <= (knownValueLogicalOrders[storageKey] ?? 0)
            if sourcePredatesKnownValue && !isKnownValue && !isPendingSourceValue {
                recordKnownValue(currentValue, for: storageKey)
                recordAcceptedMutation(nil, logicalOrder: notificationOrder, for: storageKey)
                return false
            }
        }

        return true
    }

    private func recordKnownValue<Value: SettingCodable>(
        _ value: Value,
        logicalOrder: UInt64 = DispatchTime.now().uptimeNanoseconds,
        for storageKey: String
    ) {
        knownValues[storageKey] = value
        knownValueLogicalOrders[storageKey] = max(knownValueLogicalOrders[storageKey] ?? 0, logicalOrder)
    }

    private func recordSourceLessObservedMutation<Value: SettingCodable>(
        value: Value, logicalOrder: UInt64, for storageKey: String, recordsAcceptedMutation: Bool = false
    ) {
        if recordsAcceptedMutation || !knownValue(value, matchesValueFor: storageKey) {
            recordAcceptedMutation(nil, logicalOrder: logicalOrder, for: storageKey)
        }
        recordKnownValue(value, logicalOrder: logicalOrder, for: storageKey)
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
        let logicalOrder = source?.logicalOrder ?? sourceLessLogicalOrder ?? DispatchTime.now().uptimeNanoseconds
        let acceptedOrder = max(acceptedMutationLogicalOrders[storageKey] ?? 0, logicalOrder)
        acceptedMutationLogicalOrders[storageKey] = acceptedOrder
        if let source {
            var sourcesByOwner = acceptedMutationSourcesByOwner[storageKey]?.filter { $0.value.logicalOrder == acceptedOrder } ?? [:]
            if let acceptedSource = sourcesByOwner[source.ownerID],
               source.logicalOrder < acceptedSource.logicalOrder
                || (source.logicalOrder == acceptedSource.logicalOrder
                    && source.sequence <= acceptedSource.sequence) {
                return
            }
            if source.logicalOrder == acceptedOrder {
                sourcesByOwner[source.ownerID] = source
            }
            acceptedMutationSourcesByOwner[storageKey] = sourcesByOwner
        } else {
            acceptedMutationSourcesByOwner.removeValue(forKey: storageKey)
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
        deliverPendingMutationSourceWhenValueDiffersFrom previousValue: Value? = nil,
        includeMutationSourceMetadata: Bool = true,
        includeMutationSourceMetadataWhenValueDiffersFrom previousMetadataValue: Value? = nil,
        supersedesPendingMutationSource: Bool = false,
        isInitialSnapshot: Bool = false
    ) -> (
        event: UserDefaultsSettingsValueEvent<Value>,
        consumedSourceSequence: UInt64
    ) {
        let value = storage.value(for: key)
        let valueDiffersForPendingDelivery = previousValue.map { value != $0 } ?? false
        let valueDiffersForMetadata = previousMetadataValue.map { value != $0 } ?? false
        let shouldIncludeMutationSourceMetadata = includeMutationSourceMetadata || valueDiffersForMetadata
        let shouldDeliverPendingMutationSource = deliverPendingMutationSourceWhenUnobserved
            || valueDiffersForPendingDelivery
        var nextConsumedSourceSequence = consumedSourceSequence
        var source: UserDefaultsSettingsMutationSource?
        var supersededSource: UserDefaultsSettingsMutationSource?
        if shouldIncludeMutationSourceMetadata,
           let record = mutationSources[key.userDefaultsKey],
           record.sequence > consumedSourceSequence || includedMutationSources.contains(record.source) {
            nextConsumedSourceSequence = max(record.sequence, consumedSourceSequence)
            if record.matches(value) {
                if includedMutationSources.contains(record.source)
                    || deliveredMutationSource == record.source
                    || (shouldDeliverPendingMutationSource
                        && !supersedesPendingMutationSource) {
                    source = record.source
                } else {
                    supersededSource = record.source
                }
            } else {
                supersededSource = record.source
            }
        }
        if shouldIncludeMutationSourceMetadata,
           source == nil,
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
    public nonisolated func values<Value>(for key: DefaultsKey<Value>) -> AsyncStream<Value> {
        let storage = self.storage
        let observedMutationWatermarks = self.observedMutationWatermarks
        let storageKey = key.userDefaultsKey
        return AsyncStream<Value>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            typealias Signal = (isBackingDefaultsNotification: Bool, canCarryActiveMutationSource: Bool, logicalOrder: UInt64)
            let (signals, signalContinuation) = AsyncStream<Signal>.makeStream(bufferingPolicy: .bufferingNewest(1))

            let observer = storage.addDidChangeObserver { [weak self] isBackingDefaultsNotification, canCarryActiveMutationSource in
                guard self != nil else { return }
                let logicalOrder = DispatchTime.now().uptimeNanoseconds
                _ = observedMutationWatermarks.recordNotification(
                    logicalOrder: logicalOrder,
                    isBackingDefaultsNotification: isBackingDefaultsNotification,
                    canCarryActiveMutationSource: canCarryActiveMutationSource,
                    for: storageKey
                )
                signalContinuation.yield((isBackingDefaultsNotification, canCarryActiveMutationSource, logicalOrder))
            }

            let drainTask = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                var lastYielded = await self.value(for: key)
                await self.recordKnownValue(lastYielded, for: storageKey)
                continuation.yield(lastYielded)

                for await signal in signals {
                    if Task.isCancelled { break }
                    let current = await self.value(for: key)
                    if current != lastYielded {
                        lastYielded = current
                        await self.recordSourceLessObservedMutation(
                            value: current,
                            logicalOrder: signal.logicalOrder,
                            for: storageKey
                        )
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
            typealias Signal = (
                isBackingDefaultsNotification: Bool,
                canCarryActiveMutationSource: Bool,
                logicalOrder: UInt64,
                deliveredMutationSource: UserDefaultsSettingsMutationSource?
            )
            let (signals, signalContinuation) = AsyncStream<Signal>.makeStream(bufferingPolicy: .bufferingNewest(1))

            let observer = storage.addDidChangeObserver { [weak self] isBackingDefaultsNotification, canCarryActiveMutationSource in
                guard self != nil else { return }
                let logicalOrder = DispatchTime.now().uptimeNanoseconds
                let deliveredMutationSource = observedMutationWatermarks.recordNotification(
                    logicalOrder: logicalOrder,
                    isBackingDefaultsNotification: isBackingDefaultsNotification,
                    canCarryActiveMutationSource: canCarryActiveMutationSource,
                    for: storageKey
                )
                signalContinuation.yield((
                    isBackingDefaultsNotification,
                    canCarryActiveMutationSource,
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
                        deliverPendingMutationSourceWhenUnobserved: signal.isBackingDefaultsNotification,
                        deliverPendingMutationSourceWhenValueDiffersFrom: lastYieldedEvent.value,
                        includeMutationSourceMetadata: signal.isBackingDefaultsNotification
                            || signal.deliveredMutationSource != nil,
                        includeMutationSourceMetadataWhenValueDiffersFrom: lastYieldedEvent.value
                    )
                    consumedSourceSequence = snapshot.consumedSourceSequence
                    var currentEvent = snapshot.event
                    if signal.isBackingDefaultsNotification,
                       signal.deliveredMutationSource == nil,
                       currentEvent.value == lastYieldedEvent.value,
                       currentEvent.mutationSource == nil,
                       currentEvent.supersededMutationSource == nil,
                       lastYieldedEvent.mutationSource != nil {
                        currentEvent = UserDefaultsSettingsValueEvent(
                            value: currentEvent.value,
                            supersededMutationSources: lastYieldedEvent.deliveryMutationSources
                        )
                    }
                    if currentEvent.mutationSource == nil,
                       (currentEvent.value != lastYieldedEvent.value
                        || currentEvent.supersededMutationSource != nil) {
                        await self.recordSourceLessObservedMutation(
                            value: currentEvent.value,
                            logicalOrder: signal.logicalOrder,
                            for: key.userDefaultsKey,
                            recordsAcceptedMutation: currentEvent.supersededMutationSource != nil
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
