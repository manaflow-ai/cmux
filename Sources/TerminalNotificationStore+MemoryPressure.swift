import Foundation

extension TerminalNotificationStore {
    private static let memoryPressureThrottleCacheMaxEntries = 512
    private static let memoryPressureThrottleCacheStaleAge: TimeInterval = 60 * 60

    @discardableResult
    func trimMemoryPressureCaches(now: Date = Date()) -> Int {
        let cooldownTrimmed = cooldownTracker.trim(
            now: now,
            staleAge: Self.memoryPressureThrottleCacheStaleAge,
            maxEntries: Self.memoryPressureThrottleCacheMaxEntries
        )
        let hookFailureTrimmed = notificationHookFailureThrottle.trim(
            now: now,
            staleAge: Self.memoryPressureThrottleCacheStaleAge,
            maxEntries: Self.memoryPressureThrottleCacheMaxEntries
        )
        return cooldownTrimmed + hookFailureTrimmed
    }
}
