import os

/// Publishes UserDefaults notification ordering before actor turns run.
///
/// `@unchecked Sendable` is safe because every mutation and read of the
/// dictionary is guarded by `logicalOrders`.
final class UserDefaultsSettingsObservedMutationWatermarks: @unchecked Sendable {
    // NotificationCenter observer callbacks are synchronous and non-async. This
    // lock publishes a tiny per-key timestamp before a later actor-isolated
    // write can run; the actor performs typed value checks only when needed.
    private let logicalOrders = OSAllocatedUnfairLock(initialState: [String: UInt64]())

    func recordNotification(logicalOrder: UInt64, for storageKey: String) {
        logicalOrders.withLock { logicalOrders in
            logicalOrders[storageKey] = max(logicalOrders[storageKey] ?? 0, logicalOrder)
        }
    }

    func latestNotificationLogicalOrder(for storageKey: String) -> UInt64? {
        logicalOrders.withLock { logicalOrders in
            logicalOrders[storageKey]
        }
    }
}
