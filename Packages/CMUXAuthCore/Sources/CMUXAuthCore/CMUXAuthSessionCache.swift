import Foundation

public protocol CMUXAuthKeyValueStore: AnyObject {
    func bool(forKey defaultName: String) -> Bool
    func data(forKey defaultName: String) -> Data?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: CMUXAuthKeyValueStore {}

public final class CMUXAuthSessionCache: @unchecked Sendable {
    private let keyValueStore: CMUXAuthKeyValueStore
    private let key: String

    public init(keyValueStore: CMUXAuthKeyValueStore, key: String) {
        self.keyValueStore = keyValueStore
        self.key = key
    }

    public var hasTokens: Bool {
        keyValueStore.bool(forKey: key)
    }

    public func setHasTokens(_ value: Bool) {
        keyValueStore.set(value, forKey: key)
    }

    public func clear() {
        keyValueStore.removeObject(forKey: key)
    }
}
