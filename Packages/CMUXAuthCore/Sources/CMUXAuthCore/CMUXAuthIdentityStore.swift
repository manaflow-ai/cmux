import Foundation

public final class CMUXAuthIdentityStore: @unchecked Sendable {
    private let keyValueStore: CMUXAuthKeyValueStore
    private let key: String
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(keyValueStore: CMUXAuthKeyValueStore, key: String) {
        self.keyValueStore = keyValueStore
        self.key = key
    }

    public func save(_ user: CMUXAuthUser) throws {
        let data = try encoder.encode(user)
        keyValueStore.set(data, forKey: key)
    }

    public func load() throws -> CMUXAuthUser? {
        guard let data = keyValueStore.data(forKey: key) else {
            return nil
        }
        return try decoder.decode(CMUXAuthUser.self, from: data)
    }

    public func clear() {
        keyValueStore.removeObject(forKey: key)
    }
}
