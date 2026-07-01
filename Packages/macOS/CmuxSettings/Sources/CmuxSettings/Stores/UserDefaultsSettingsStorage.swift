import Foundation

// Safety: `UserDefaults` documents thread-safe access. This wrapper exposes
// only typed read/write/remove operations and never hands out the defaults
// instance across actor boundaries.
final class UserDefaultsSettingsStorage: @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func value<Value>(for key: DefaultsKey<Value>) -> Value {
        key.value(in: defaults)
    }

    func set<Value>(_ value: Value, for key: DefaultsKey<Value>) {
        key.set(value, in: defaults)
    }

    func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }

    func addDidChangeObserver(
        _ handler: @escaping @Sendable (
            _ isBackingDefaultsNotification: Bool,
            _ canCarryActiveMutationSource: Bool
        ) -> Void
    ) -> NotificationObserverToken {
        let defaultsID = ObjectIdentifier(defaults)
        return NotificationObserverToken(
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: nil
            ) { notification in
                let objectID = notification.object.map { ObjectIdentifier($0 as AnyObject) }
                let isBackingDefaultsNotification = objectID == defaultsID
                handler(isBackingDefaultsNotification, objectID == nil || isBackingDefaultsNotification)
            }
        )
    }
}
