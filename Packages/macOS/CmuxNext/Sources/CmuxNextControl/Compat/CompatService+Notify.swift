import CmuxNextDaemon

extension CompatService {
    /// Posts a daemon notification and tags its source in the app
    /// (`expectNotification` first, since the daemon's event can arrive
    /// before its reply; then `noteNotification`, nil on failure).
    func createNotification(title: String, body: String, level: NotificationLevel = .info,
                            surface: SurfaceID?, session: String? = nil, source: String) async throws -> NotificationID {
        _ = try? await perform(.expectNotification)
        do {
            let id = try await daemon("notify", session: session) { try await $0.notify(title: title, body: body, level: level, surface: surface) }
            _ = try? await perform(.noteNotification(id: id.rawValue, source: source))
            return id
        } catch {
            _ = try? await perform(.noteNotification(id: nil, source: source))
            throw error
        }
    }
}
