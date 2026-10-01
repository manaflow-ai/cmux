import CmuxNextDaemon

extension CompatService {
    /// Posts a daemon notification with its source (`cli`, `agent`); the
    /// daemon puts the source on the event and the tab marker
    /// (`notification-source-v1`).
    func createNotification(title: String, body: String, level: NotificationLevel = .info,
                            surface: SurfaceID?, session: String? = nil, source: String) async throws -> NotificationID {
        try await daemon("notify", session: session) {
            try await $0.notify(title: title, body: body, level: level, surface: surface, source: source)
        }
    }
}
