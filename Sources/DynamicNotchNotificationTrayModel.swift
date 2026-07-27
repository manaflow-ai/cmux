import Foundation
import Observation

/// Main-actor state for the accumulated Dynamic Notch notification tray.
@MainActor
@Observable
final class DynamicNotchNotificationTrayModel {
    private(set) var notifications: [TerminalNotification] = []
    private(set) var isExpanded = false

    @discardableResult
    func enqueue(_ notification: TerminalNotification) -> Bool {
        guard !notifications.contains(where: { $0.id == notification.id }) else {
            return false
        }
        notifications.insert(notification, at: 0)
        return true
    }

    func notification(id: UUID) -> TerminalNotification? {
        notifications.first(where: { $0.id == id })
    }

    @discardableResult
    func remove(id: UUID) -> TerminalNotification? {
        guard let index = notifications.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let notification = notifications.remove(at: index)
        if notifications.isEmpty {
            isExpanded = false
        }
        return notification
    }

    func removeAll() -> [TerminalNotification] {
        let removed = notifications
        notifications.removeAll()
        isExpanded = false
        return removed
    }

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded && !notifications.isEmpty
    }
}
