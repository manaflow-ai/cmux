import Foundation

extension TerminalNotificationStore {
    private static let memoryPressureThrottleCacheMaxEntries = 512
    private static let memoryPressureThrottleCacheStaleAge: TimeInterval = 60 * 60

    @discardableResult
    func trimMemoryPressureCaches(now: Date = Date()) -> Int {
        let beforeCount = lastNotificationDateByCooldownKey.count
            + lastNotificationHookFailureDateByKey.count

        lastNotificationDateByCooldownKey = Self.trimDateCache(
            lastNotificationDateByCooldownKey,
            now: now,
            staleAge: Self.memoryPressureThrottleCacheStaleAge,
            maxEntries: Self.memoryPressureThrottleCacheMaxEntries
        )
        lastNotificationHookFailureDateByKey = Self.trimDateCache(
            lastNotificationHookFailureDateByKey,
            now: now,
            staleAge: Self.memoryPressureThrottleCacheStaleAge,
            maxEntries: Self.memoryPressureThrottleCacheMaxEntries
        )

        let afterCount = lastNotificationDateByCooldownKey.count
            + lastNotificationHookFailureDateByKey.count
        return Swift.max(0, beforeCount - afterCount)
    }

    private static func trimDateCache<Key: Hashable>(
        _ cache: [Key: Date],
        now: Date,
        staleAge: TimeInterval,
        maxEntries: Int
    ) -> [Key: Date] {
        let freshEntries = cache.filter { _, date in
            now.timeIntervalSince(date) <= staleAge
        }
        guard freshEntries.count > maxEntries else { return freshEntries }
        return Dictionary(
            uniqueKeysWithValues: freshEntries
                .sorted { lhs, rhs in lhs.value > rhs.value }
                .prefix(maxEntries)
                .map { ($0.key, $0.value) }
        )
    }
}
