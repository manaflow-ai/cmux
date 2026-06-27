import os

/// Publishes UserDefaults notification ordering before actor turns run.
///
/// `@unchecked Sendable` is safe because every mutation and read of the
/// dictionaries is guarded by `state`.
final class UserDefaultsSettingsObservedMutationWatermarks: @unchecked Sendable {
    private struct State {
        var logicalOrders: [String: UInt64] = [:]
        var activeMutationSources: [String: UserDefaultsSettingsMutationSource] = [:]
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

    func recordNotification(logicalOrder: UInt64, for storageKey: String) {
        state.withLock { state in
            state.logicalOrders[storageKey] = max(state.logicalOrders[storageKey] ?? 0, logicalOrder)
        }
    }

    func latestNotificationLogicalOrder(for storageKey: String) -> UInt64? {
        state.withLock { state in
            state.logicalOrders[storageKey]
        }
    }

    func activeMutationSource(for storageKey: String) -> UserDefaultsSettingsMutationSource? {
        state.withLock { state in
            state.activeMutationSources[storageKey]
        }
    }
}
