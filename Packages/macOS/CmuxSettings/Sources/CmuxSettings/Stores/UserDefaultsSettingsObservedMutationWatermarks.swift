import os

/// Tracks UserDefaults observations that must be visible before actor turns run.
final class UserDefaultsSettingsObservedMutationWatermarks: @unchecked Sendable {
    private struct State {
        var acceptedLogicalOrders: [String: UInt64] = [:]
        var knownValues: [String: any Sendable] = [:]
        var mutationSources: [String: UserDefaultsSettingsMutationSourceRecord] = [:]
    }

    // NotificationCenter observer callbacks are synchronous and non-async. This
    // sidecar publishes the small per-key watermark before a later actor-isolated
    // write can run; actor-only publication is the race this type prevents.
    private let state = OSAllocatedUnfairLock(initialState: State())

    func acceptedLogicalOrder(for storageKey: String) -> UInt64? {
        state.withLock { state in
            state.acceptedLogicalOrders[storageKey]
        }
    }

    func recordKnownValue<Value: SettingCodable>(_ value: Value, for storageKey: String) {
        state.withLock { state in
            state.knownValues[storageKey] = value
        }
    }

    func clearKnownValue(for storageKey: String) {
        _ = state.withLock { state in
            state.knownValues.removeValue(forKey: storageKey)
        }
    }

    func recordMutationSource<Value: SettingCodable>(
        _ source: UserDefaultsSettingsMutationSource,
        sequence: UInt64,
        value: Value,
        for storageKey: String
    ) {
        state.withLock { state in
            state.mutationSources[storageKey] = UserDefaultsSettingsMutationSourceRecord(
                source: source,
                sequence: sequence,
                value: value
            )
        }
    }

    func clearMutationSource(for storageKey: String) {
        _ = state.withLock { state in
            state.mutationSources.removeValue(forKey: storageKey)
        }
    }

    func recordObservedValue<Value: SettingCodable>(
        _ value: Value,
        logicalOrder: UInt64,
        for storageKey: String
    ) {
        state.withLock { state in
            if let source = state.mutationSources[storageKey], source.matches(value) {
                state.knownValues[storageKey] = value
                return
            }

            if let knownValue = state.knownValues[storageKey] as? Value,
               knownValue == value {
                return
            }

            state.knownValues[storageKey] = value
            state.acceptedLogicalOrders[storageKey] = max(
                state.acceptedLogicalOrders[storageKey] ?? 0,
                logicalOrder
            )
        }
    }
}
