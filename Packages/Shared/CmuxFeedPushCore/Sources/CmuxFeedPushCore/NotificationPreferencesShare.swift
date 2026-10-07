import Foundation

/// How the app hands this device's preferences to its Notification Service
/// extension: JSON under one key of the shared store both processes read.
public struct NotificationPreferencesShare: Sendable {
    public static let key = "cmux.notify.preferences.v1"

    public let read: @Sendable () -> Data?
    public let write: @Sendable (Data?) -> Void

    public init(read: @escaping @Sendable () -> Data?, write: @escaping @Sendable (Data?) -> Void) {
        self.read = read
        self.write = write
    }

    public func load() -> NotificationPreferences? {
        read().flatMap { try? JSONDecoder().decode(NotificationPreferences.self, from: $0) }
    }

    public func save(_ preferences: NotificationPreferences) {
        write(try? JSONEncoder().encode(preferences))
    }
}
