import AppKit
import Combine
import Foundation

/// A pane tab that hosts the notification feed and forwarding controls.
@MainActor
final class NotificationsPanel: Panel {
    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .notifications

    var displayTitle: String {
        String(localized: "notifications.title", defaultValue: "Notifications")
    }

    var displayIcon: String? { "bell" }

    init(id: UUID = UUID()) {
        self.id = id
    }

    func close() {}
    func focus() {}
    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}
