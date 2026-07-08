import Dispatch
import Foundation

extension UserDefaultsSettingsStore {
    /// Returns a coalescing stream of the current value and later changes.
    public nonisolated func values<Value>(for key: DefaultsKey<Value>) -> AsyncStream<Value> {
        let storage = self.storage
        let observedMutationWatermarks = self.observedMutationWatermarks
        let storageKey = key.userDefaultsKey
        return AsyncStream<Value>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let (signals, signalContinuation, storeSignalToken) = storeSignals.makeStream(for: storageKey)

            let observer = storage.addDidChangeObserver { [weak self] isBackingDefaultsNotification, canCarryActiveMutationSource in
                guard self != nil else { return }
                let logicalOrder = DispatchTime.now().uptimeNanoseconds
                _ = observedMutationWatermarks.recordNotification(
                    logicalOrder: logicalOrder,
                    isBackingDefaultsNotification: isBackingDefaultsNotification,
                    canCarryActiveMutationSource: canCarryActiveMutationSource,
                    for: storageKey
                )
                signalContinuation.yield(
                    UserDefaultsSettingsStoreSignal(
                        isBackingDefaultsNotification: isBackingDefaultsNotification,
                        canCarryActiveMutationSource: canCarryActiveMutationSource,
                        logicalOrder: logicalOrder,
                        deliveredMutationSource: nil
                    )
                )
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
                storeSignalToken.remove()
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
            let (signals, signalContinuation, storeSignalToken) = storeSignals.makeStream(for: storageKey)

            let observer = storage.addDidChangeObserver { [weak self] isBackingDefaultsNotification, canCarryActiveMutationSource in
                guard self != nil else { return }
                let logicalOrder = DispatchTime.now().uptimeNanoseconds
                let deliveredMutationSource = observedMutationWatermarks.recordNotification(
                    logicalOrder: logicalOrder,
                    isBackingDefaultsNotification: isBackingDefaultsNotification,
                    canCarryActiveMutationSource: canCarryActiveMutationSource,
                    for: storageKey
                )
                signalContinuation.yield(
                    UserDefaultsSettingsStoreSignal(
                        isBackingDefaultsNotification: isBackingDefaultsNotification,
                        canCarryActiveMutationSource: canCarryActiveMutationSource,
                        logicalOrder: logicalOrder,
                        deliveredMutationSource: deliveredMutationSource
                    )
                )
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
                    let recordsSourceLessFence = signal.isBackingDefaultsNotification && signal.deliveredMutationSource == nil
                        && currentEvent.value == lastYieldedEvent.value
                        && currentEvent.mutationSource == nil && currentEvent.supersededMutationSource == nil
                    if currentEvent.mutationSource == nil,
                       (currentEvent.value != lastYieldedEvent.value
                        || currentEvent.supersededMutationSource != nil
                        || recordsSourceLessFence) {
                        await self.recordSourceLessObservedMutation(
                            value: currentEvent.value,
                            logicalOrder: signal.logicalOrder,
                            for: key.userDefaultsKey,
                            recordsAcceptedMutation: currentEvent.supersededMutationSource != nil
                                || recordsSourceLessFence
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
                storeSignalToken.remove()
                observer.remove()
            }
        }
    }
}
