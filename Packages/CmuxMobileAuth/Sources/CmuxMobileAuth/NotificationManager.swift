@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private init() {}

    func syncTokenIfPossible() async {}

    func unregisterFromServer() async {}
}
