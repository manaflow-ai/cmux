import os

/// Publishes UserDefaults notification ordering before actor turns run.
///
/// `@unchecked Sendable` is safe because every mutation and read of the
/// dictionaries is guarded by `state`.
final class UserDefaultsSettingsObservedMutationWatermarks: @unchecked Sendable {
    private struct State {
        var logicalOrders: [String: UInt64] = [:]
        var activeMutationSources: [String: UserDefaultsSettingsMutationSource] = [:]
        var backingNotifications: [String: (
            logicalOrder: UInt64,
            mutationSource: UserDefaultsSettingsMutationSource?
        )] = [:]
    }

    // NotificationCenter observer callbacks are synchronous and non-async. This
    // lock publishes tiny per-key markers before a later actor-isolated write
    // can run; the actor performs typed value checks only when needed.
    private let state = OSAllocatedUnfairLock(initialState: State())

    func beginMutationSource(_ source: UserDefaultsSettingsMutationSource, for storageKey: String) {
        state.withLock { state in
            state.activeMutationSources[storageKey] = source
        }
    }

    func endMutationSource(_ source: UserDefaultsSettingsMutationSource, for storageKey: String) {
        state.withLock { state in
            if state.activeMutationSources[storageKey] == source {
                state.activeMutationSources.removeValue(forKey: storageKey)
            }
        }
    }

    func recordNotification(
        logicalOrder: UInt64,
        isBackingDefaultsNotification: Bool,
        canCarryActiveMutationSource: Bool,
        for storageKey: String
    ) -> UserDefaultsSettingsMutationSource? {
        return state.withLock { state in
            let mutationSource = canCarryActiveMutationSource
                ? state.activeMutationSources[storageKey]
                : nil
            state.logicalOrders[storageKey] = max(state.logicalOrders[storageKey] ?? 0, logicalOrder)
            if isBackingDefaultsNotification || mutationSource != nil {
                state.backingNotifications[storageKey] = (logicalOrder, mutationSource)
            }
            return mutationSource
        }
    }

    func latestNotificationLogicalOrder(for storageKey: String) -> UInt64? {
        state.withLock { state in
            state.logicalOrders[storageKey]
        }
    }

    func latestBackingNotification(
        after logicalOrder: UInt64,
        for storageKey: String
    ) -> (logicalOrder: UInt64, mutationSource: UserDefaultsSettingsMutationSource?)? {
        state.withLock { state in
            guard let record = state.backingNotifications[storageKey],
                  record.logicalOrder > logicalOrder
            else { return nil }
            return record
        }
    }
}
