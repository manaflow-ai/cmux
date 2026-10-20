import Foundation

/// The text of a tab's unread notification, which its workspace's hover card
/// shows (and its sidebar row, with `sidebar.workspaceRow.notification` on,
/// classic's `sidebar.showNotificationMessage`): the body, else the title, trimmed.
extension DaemonStore {
    /// How many live notifications keep their text; the oldest go first.
    static let notificationTextLimit = 512

    /// The text of `tab`'s unread notification, nil when it has none. A
    /// notification that arrived while connected is matched by id; one
    /// posted before the app connected comes from the ledger.
    public func notificationText(for tab: TabModel) -> String? {
        guard let marker = tab.notification, marker.unread else { return nil }
        return notificationTexts[marker.notification] ?? ledgerNotificationTexts[tab.surface]
    }

    /// Seeds the texts of notifications posted before this connection from
    /// the `list-notifications` ledger (newest first): each surface keeps its
    /// newest unacknowledged one.
    public func seedNotificationTexts(_ ledger: [ListNotificationsRequest.Entry]) {
        var texts: [SurfaceID: String] = [:]
        for entry in ledger where !entry.acknowledged {
            guard let surface = entry.surface, texts[surface] == nil,
                  let text = Self.notificationText(title: entry.title, body: entry.body) else { continue }
            texts[surface] = text
        }
        if ledgerNotificationTexts != texts { ledgerNotificationTexts = texts }
    }

    func recordNotificationText(_ notification: DaemonNotification) {
        // A newer notification replaces the surface's ledger text, even a blank one.
        if let surface = notification.surface, ledgerNotificationTexts[surface] != nil { ledgerNotificationTexts[surface] = nil }
        guard let text = Self.notificationText(title: notification.title, body: notification.body) else { return }
        notificationTexts[notification.notification] = text
        if notificationTexts.count > Self.notificationTextLimit,
           let oldest = notificationTexts.keys.min(by: { $0.rawValue < $1.rawValue }) {
            notificationTexts[oldest] = nil
        }
    }

    /// The body, else the title, trimmed; nil when both are blank.
    static func notificationText(title: String, body: String) -> String? {
        for text in [body, title] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
