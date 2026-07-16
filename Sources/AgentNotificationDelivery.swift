import CmuxSettings
import Foundation

private final class AgentNotificationDeduper: @unchecked Sendable {
    static let shared = AgentNotificationDeduper()

    private let lock = NSLock()
    private var recent: [String: TimeInterval] = [:]

    func claim(_ key: String, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        lock.withLock {
            recent = recent.filter { now - $0.value <= 60 * 60 }
            guard recent[key] == nil else { return false }
            recent[key] = now
            if recent.count > 128 {
                let keep = recent.sorted { lhs, rhs in lhs.value > rhs.value }.prefix(128)
                recent = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
            return true
        }
    }
}

/// Applies agent notification policy and publishes accepted events through the shared mutation bus.
struct AgentNotificationDelivery: Sendable {
    private let permissionEnabled: Bool
    private let turnMode: AgentTurnCompleteMode
    private let idleEnabled: Bool

    init(defaults: UserDefaults = .standard) {
        let catalog = NotificationsCatalogSection()
        self.permissionEnabled = catalog.agentPermissionPrompt.value(in: defaults)
        self.turnMode = AgentTurnCompleteMode(
            rawValue: catalog.agentTurnComplete.value(in: defaults)
        ) ?? .whenIdle
        self.idleEnabled = catalog.agentIdleReminder.value(in: defaults)
    }

    /// Gates and enqueues the same notification event for hooks and PTY prompt detectors.
    @discardableResult
    func enqueue(
        workspaceID: UUID,
        surfaceID: UUID,
        title: String,
        subtitle: String,
        body: String,
        category: AgentNotifyCategory?,
        pending: Bool,
        coalesces: Bool = false,
        dedupeKey: String? = nil
    ) -> Bool {
        if let category,
           !agentNotificationShouldDeliver(
               category: category,
               pending: pending,
               permissionEnabled: permissionEnabled,
               turnMode: turnMode,
               idleEnabled: idleEnabled
           ) {
            return false
        }
        if let dedupeKey, !AgentNotificationDeduper.shared.claim(dedupeKey) {
            return false
        }
        TerminalMutationBus.shared.enqueueNotification(
            tabId: workspaceID,
            surfaceId: surfaceID,
            title: title,
            subtitle: subtitle,
            body: body,
            coalesces: coalesces
        )
        return true
    }
}
