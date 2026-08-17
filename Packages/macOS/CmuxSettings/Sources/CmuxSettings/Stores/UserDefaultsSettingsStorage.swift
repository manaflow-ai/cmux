import Foundation
import os

// Safety: NotificationCenter callbacks may arrive concurrently. Every read and
// mutation of the nesting depth is serialized by `OSAllocatedUnfairLock`, and
// the class exposes no unprotected state.
private final class RemoteDefaultNotificationState: @unchecked Sendable {
    private let depth = OSAllocatedUnfairLock(initialState: 0)

    func begin() {
        depth.withLock { $0 += 1 }
    }

    func end() {
        depth.withLock { $0 = max(0, $0 - 1) }
    }

    var isActive: Bool {
        depth.withLock { $0 > 0 }
    }
}

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

    func resolution<Value>(for key: DefaultsKey<Value>) -> DefaultsValueResolution<Value> {
        key.resolution(in: defaults)
    }

    func valueIfPresent<Value>(for key: DefaultsKey<Value>) -> Value? {
        Value.decodeFromUserDefaults(defaults.object(forKey: key.userDefaultsKey))
    }

    func inheritedValue<Value>(for key: DefaultsKey<Value>) -> Value {
        key.inheritedValue(in: defaults)
    }

    func inheritedValue(for key: AnySettingKey) -> (any Sendable)? {
        key.userDefaultsInheritedValue(defaults)
    }

    func hasStoredValue(for key: String) -> Bool {
        defaults.object(forKey: key) != nil
    }

    func set<Value>(_ value: Value, for key: DefaultsKey<Value>) {
        key.set(value, in: defaults)
    }

    func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }

    func addDidChangeObserver(
        for storageKey: String? = nil,
        _ handler: @escaping @Sendable (
            _ isBackingDefaultsNotification: Bool,
            _ canCarryActiveMutationSource: Bool,
            _ isInheritedDefaultNotification: Bool
        ) -> Void
    ) -> NotificationObserverToken {
        let defaultsID = ObjectIdentifier(defaults)
        let remoteDefaultState = RemoteDefaultNotificationState()
        let matchesStorageKey: @Sendable (Notification) -> Bool = { notification in
            guard let storageKey else { return true }
            return notification.userInfo?[
                CmuxSettingsRemoteDefaultNotification.storageKeyUserInfoKey
            ] as? String == storageKey
        }
        var tokens = [
            notificationCenter.addObserver(
                forName: .cmuxSettingsRemoteDefaultWillChange,
                object: defaults,
                queue: nil
            ) { notification in
                guard matchesStorageKey(notification) else { return }
                remoteDefaultState.begin()
            },
            notificationCenter.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: nil
            ) { notification in
                let objectID = notification.object.map { ObjectIdentifier($0 as AnyObject) }
                let isBackingDefaultsNotification = objectID == defaultsID
                let isInheritedDefaultNotification = remoteDefaultState.isActive
                    && (objectID == nil || isBackingDefaultsNotification)
                handler(
                    isBackingDefaultsNotification,
                    !isInheritedDefaultNotification
                        && (objectID == nil || isBackingDefaultsNotification),
                    isInheritedDefaultNotification
                )
            }
        ]
        if storageKey != nil {
            tokens.append(
                notificationCenter.addObserver(
                    forName: .cmuxSettingsRemoteDefaultDidChange,
                    object: defaults,
                    queue: nil
                ) { notification in
                    guard matchesStorageKey(notification) else { return }
                    handler(true, false, true)
                    remoteDefaultState.end()
                }
            )
        } else {
            tokens.append(
                notificationCenter.addObserver(
                    forName: .cmuxSettingsRemoteDefaultDidChange,
                    object: defaults,
                    queue: nil
                ) { _ in
                    remoteDefaultState.end()
                }
            )
        }
        return NotificationObserverToken(tokens, notificationCenter: notificationCenter)
    }
}
