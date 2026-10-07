import Foundation

@MainActor
final class NotificationCacheMemoryPressureResponder: MemoryPressureResponder {
    let memoryPressureResponderID = "terminal-notification-throttle-caches"
    let memoryPressureMinimumSeverity: MemoryPressureSeverity = .critical
    let memoryPressurePriority = 10

    private weak var store: TerminalNotificationStore?

    init(store: TerminalNotificationStore) {
        self.store = store
    }

    func shedMemory(for snapshot: MemoryPressureSnapshot) -> MemoryPressureShedResult {
        let trimmedCount = store?.trimMemoryPressureCaches(now: snapshot.sampledAt) ?? 0
        return MemoryPressureShedResult(
            reclaimedItemCount: trimmedCount,
            detail: "notification-throttle-caches"
        )
    }
}
