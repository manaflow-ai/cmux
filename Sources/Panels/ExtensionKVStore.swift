import CryptoKit
import Foundation

struct ExtensionKVStore {
    static let maxKeyLength = 256
    static let maxValueBytes = 256 * 1024
    static let maxNamespaceBytes = 1024 * 1024

    let bundlePath: String
    let contentHash: String
    var defaults: UserDefaults = .standard

    init(bundle: ExtensionBundleDescriptor, defaults: UserDefaults = .standard) {
        self.bundlePath = bundle.bundlePath
        self.contentHash = bundle.contentHash
        self.defaults = defaults
    }

    func get(_ key: String) -> Any {
        ExtensionBridgeCodec.decodeJSONFragment(store()[key]) ?? NSNull()
    }

    func set(key: String, encodedValue: String) -> Result<Void, ExtensionKVStoreError> {
        guard key.utf8.count <= Self.maxKeyLength else {
            return .failure(.invalidKey("Key exceeds \(Self.maxKeyLength) bytes"))
        }
        let encodedBytes = encodedValue.utf8.count
        guard encodedBytes <= Self.maxValueBytes else {
            return .failure(.quotaExceeded("Value exceeds \(Self.maxValueBytes) bytes"))
        }

        var nextStore = store()
        nextStore[key] = encodedValue
        let totalBytes = nextStore.reduce(0) { partial, entry in
            partial + entry.key.utf8.count + entry.value.utf8.count
        }
        guard totalBytes <= Self.maxNamespaceBytes else {
            return .failure(.quotaExceeded("Namespace exceeds \(Self.maxNamespaceBytes) bytes"))
        }

        defaults.set(nextStore, forKey: defaultsKey)
        return .success(())
    }

    func remove(_ key: String) {
        var nextStore = store()
        nextStore.removeValue(forKey: key)
        defaults.set(nextStore, forKey: defaultsKey)
    }

    func keys() -> [String] {
        store().keys.sorted()
    }

    private var defaultsKey: String {
        var keyMaterial = Data(bundlePath.utf8)
        keyMaterial.append(0)
        keyMaterial.append(Data(contentHash.utf8))
        let digest = SHA256.hash(data: keyMaterial)
            .map { String(format: "%02x", $0) }
            .joined()
        return "extensionPanel.kv.\(digest)"
    }

    private func store() -> [String: String] {
        defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }
}

enum ExtensionKVStoreError: Error {
    case invalidKey(String)
    case quotaExceeded(String)

    var bridgeCode: String {
        switch self {
        case .invalidKey:
            return "invalid_params"
        case .quotaExceeded:
            return "quota_exceeded"
        }
    }

    var message: String {
        switch self {
        case .invalidKey(let message), .quotaExceeded(let message):
            return message
        }
    }
}
