import Foundation

// Safety: `UserDefaults` documents thread-safe access. This wrapper exposes
// only typed read/write/remove operations and never hands out the defaults
// instance across actor boundaries.
final class UserDefaultsSettingsStorage: @unchecked Sendable {
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    init(defaults: UserDefaults, notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    func value<Value>(for key: DefaultsKey<Value>) -> Value {
        key.value(in: defaults)
    }

    func set<Value>(_ value: Value, for key: DefaultsKey<Value>) {
        key.set(value, in: defaults)
        postDidChangeNotification()
    }

    func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
        postDidChangeNotification()
    }

    private func postDidChangeNotification() {
        // UserDefaults can skip same-value notifications; store observers still
        // need a deterministic signal for store-owned writes.
        notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)
    }

    func addDidChangeObserver(
        _ handler: @escaping @Sendable (
            _ isBackingDefaultsNotification: Bool,
            _ canCarryActiveMutationSource: Bool
        ) -> Void
    ) -> NotificationObserverToken {
        let defaultsID = ObjectIdentifier(defaults)
        return NotificationObserverToken(
            notificationCenter.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: nil
            ) { notification in
                let objectID = notification.object.map { ObjectIdentifier($0 as AnyObject) }
                let isBackingDefaultsNotification = objectID == defaultsID
                handler(isBackingDefaultsNotification, objectID == nil || isBackingDefaultsNotification)
            },
            notificationCenter: notificationCenter
        )
    }
}
