import CryptoKit
import CmuxIrxTransport
import Foundation
import Security

struct MobileHostV2Configuration: Sendable {
    let baseURL: URL
    let environment: String
    let projectID: String
    let namespace: String
    let tag: String
    let stateDirectory: URL

    @MainActor
    static func current() throws -> Self {
        let values = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        let namespace = Bundle.main.bundleIdentifier ?? "dev.cmux"
        for key in ["CMUX_IROH_V2_ENVIRONMENT", "CMUX_IROH_V2_BASE_URL", "CMUX_IROH_V2_FORCE_RELAY"] {
            if let value = values[key] { defaults.set(value, forKey: "cmux.iroh.v2.config." + key) }
        }
        func override(_ key: String) -> String? {
            values[key] ?? defaults.string(forKey: "cmux.iroh.v2.config." + key)
                ?? Bundle.main.object(forInfoDictionaryKey: key) as? String
        }
        #if DEBUG
        let fallback = "development"
        #else
        let fallback = namespace.contains("staging") ? "staging" : "production"
        #endif
        let environment = override("CMUX_IROH_V2_ENVIRONMENT") ?? fallback
        let origin: String
        switch environment {
        case "production": origin = "https://cmux-iroh-v2.cmux-presence-worker.workers.dev"
        case "staging": origin = "https://cmux-iroh-v2-staging.cmux-presence-worker.workers.dev"
        default: origin = "https://cmux-iroh-v2-development.cmux-presence-worker.workers.dev"
        }
        guard let url = URL(string: override("CMUX_IROH_V2_BASE_URL") ?? origin),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw V2ControlFailure.scopeMismatch }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self(baseURL: url, environment: environment, projectID: AuthEnvironment.stackProjectID,
                    namespace: namespace, tag: MobileHostIdentity.instanceTag(),
                    stateDirectory: support.appendingPathComponent(namespace, isDirectory: true))
    }
}

/// Uses only new v2 storage. Stack credentials and pre-v2 identity files are untouched.
actor MobileHostV2Installation {
    private let configuration: MobileHostV2Configuration
    private let keys: V2IdentityKeyStore

    init(configuration: MobileHostV2Configuration) {
        self.configuration = configuration
        keys = V2IdentityKeyStore(applicationNamespace: configuration.namespace)
    }

    func deviceID() throws -> String {
        #if DEBUG
        let file = try debugDirectory().appendingPathComponent("installation-id")
        if FileManager.default.fileExists(atPath: file.path) {
            let value = try String(contentsOf: file, encoding: .utf8)
            guard UUID(uuidString: value) != nil else { throw V2ControlFailure.persistenceFailed }
            return value
        }
        let value = UUID().uuidString.lowercased()
        try Data(value.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return value
        #else
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.namespace + ".cmux-iroh-v2.installation",
            kSecAttrAccount as String: "device-id"]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data,
           let value = String(data: data, encoding: .utf8), UUID(uuidString: value) != nil { return value }
        guard status == errSecItemNotFound else { throw V2ControlFailure.persistenceFailed }
        let value = UUID().uuidString.lowercased()
        var create = query
        create[kSecValueData as String] = Data(value.utf8)
        create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(create as CFDictionary, nil)
        if added == errSecDuplicateItem {
            guard SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data, let stored = String(data: data, encoding: .utf8),
                  UUID(uuidString: stored) != nil else { throw V2ControlFailure.persistenceFailed }
            return stored
        }
        guard added == errSecSuccess else { throw V2ControlFailure.persistenceFailed }
        return value
        #endif
    }

    func key(identity: V2Identity) async throws -> V2IdentityKey {
        #if DEBUG
        let digest = SHA256.hash(data: try V2WireSigningCodec().encode(identity)).map { String(format: "%02x", $0) }.joined()
        let file = try debugDirectory().appendingPathComponent(digest + ".key")
        if FileManager.default.fileExists(atPath: file.path) { return try V2IdentityKey(secretKey: Data(contentsOf: file)) }
        let key = V2IdentityKey()
        try key.secretKey.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return key
        #else
        return try await keys.loadOrCreate(identity: identity)
        #endif
    }

    #if DEBUG
    private func debugDirectory() throws -> URL {
        let directory = configuration.stateDirectory.appendingPathComponent("cmux-iroh-v2/development-keys", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }
    #endif
}
