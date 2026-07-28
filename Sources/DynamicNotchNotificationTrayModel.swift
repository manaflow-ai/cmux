import CmuxSettings
import Foundation
import Observation

enum DynamicNotchNotificationPhase: Equatable {
    case retracted
    case compact
    case expanded
}

/// Main-actor state for the accumulated Dynamic Notch notification tray.
@MainActor
@Observable
final class DynamicNotchNotificationTrayModel {
    private(set) var notifications: [TerminalNotification] = []
    private(set) var phase: DynamicNotchNotificationPhase = .retracted
    private(set) var globalAppearance: DynamicNotchAppearance

    init(globalAppearance: DynamicNotchAppearance = DynamicNotchAppearance()) {
        self.globalAppearance = globalAppearance
    }

    /// Tray-wide dimensions and chrome follow the newest pending notification.
    var trayAppearance: DynamicNotchAppearance {
        guard let notification = notifications.first else {
            return globalAppearance
        }
        return appearance(for: notification)
    }

    /// Each accumulated row retains the overrides it was created with.
    func appearance(
        for notification: TerminalNotification
    ) -> DynamicNotchAppearance {
        globalAppearance.applying(notification.presentation.appearance)
    }

    @discardableResult
    func enqueue(_ notification: TerminalNotification) -> Bool {
        guard !notifications.contains(where: { $0.id == notification.id }) else {
            return false
        }
        notifications.insert(notification, at: 0)
        return true
    }

    /// Replaces superseded rows and inserts the new row in one observable
    /// mutation so the presentation never passes through an empty state.
    @discardableResult
    func upsert(
        _ notification: TerminalNotification,
        superseding identifiers: Set<UUID>
    ) -> [TerminalNotification] {
        var removed: [TerminalNotification] = []
        notifications.removeAll { existing in
            guard identifiers.contains(existing.id) || existing.id == notification.id else {
                return false
            }
            removed.append(existing)
            return true
        }
        notifications.insert(notification, at: 0)
        return removed
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
            phase = .retracted
        }
        return notification
    }

    func remove(ids: Set<UUID>) -> [TerminalNotification] {
        var removed: [TerminalNotification] = []
        notifications.removeAll { notification in
            guard ids.contains(notification.id) else { return false }
            removed.append(notification)
            return true
        }
        if notifications.isEmpty {
            phase = .retracted
        }
        return removed
    }

    func removeAll() -> [TerminalNotification] {
        let removed = notifications
        notifications.removeAll()
        phase = .retracted
        return removed
    }

    func transition(to phase: DynamicNotchNotificationPhase) {
        self.phase = notifications.isEmpty ? .retracted : phase
    }

    func setGlobalAppearance(_ appearance: DynamicNotchAppearance) {
        globalAppearance = appearance
    }
}
