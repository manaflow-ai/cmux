import Foundation

/// Serial persistence executor; JSON encoding and preference mutation never
/// run in a Cloud catalog callback or a sidebar rendering transaction.
actor CloudNotificationSyncPersistence {
    public enum Mutation: Sendable {
        case save(CloudNotificationSyncState)
        case remove
    }

    // UserDefaults explicitly supports concurrent access. Only this actor writes
    // these keys; the UI owner performs the initial read and then uses its cache.
    private nonisolated(unsafe) let defaults: UserDefaults

    @MainActor
    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func apply(_ batch: [String: Mutation]) {
        let encoder = JSONEncoder()
        for (key, mutation) in batch {
            switch mutation {
            case .save(let state):
                guard let data = try? encoder.encode(state) else { continue }
                defaults.set(data, forKey: key)
            case .remove:
                defaults.removeObject(forKey: key)
            }
        }
    }
}
