import Foundation
import Security
import Synchronization

/// Where a remembered HTTP sign-in applies: one browser profile, one server
/// (scheme, host, port), one realm and one method.
nonisolated struct BrowserHTTPCredentialKey: Hashable, Sendable {
    var profile: String
    var scheme: String
    var host: String
    var port: Int
    var realm: String
    var method: String

    init(profile: BrowserProfileID, space: URLProtectionSpace) {
        self.profile = profile.rawValue.uuidString
        scheme = space.protocol ?? "http"
        host = space.host
        port = space.port
        realm = space.realm ?? ""
        method = space.authenticationMethod
    }

    init(profile: String, scheme: String, host: String, port: Int, realm: String, method: String) {
        self.profile = profile
        self.scheme = scheme
        self.host = host
        self.port = port
        self.realm = realm
        self.method = method
    }

    /// The Keychain account: no secret, the server and realm only.
    var account: String { "\(profile)|\(scheme)://\(host):\(port)|\(method)|\(realm)" }
}

/// A user name and password the user chose to remember.
nonisolated struct BrowserHTTPRememberedLogin: Equatable, Sendable, Codable {
    var user: String
    var password: String
}

/// HTTP sign-ins the user checked "Remember password" for. Nothing goes in
/// unless they did; an off-the-record profile never reads or writes it.
nonisolated protocol BrowserHTTPCredentialStoring: Sendable {
    func login(for key: BrowserHTTPCredentialKey) -> BrowserHTTPRememberedLogin?
    func save(_ login: BrowserHTTPRememberedLogin, for key: BrowserHTTPCredentialKey)
    func forget(_ key: BrowserHTTPCredentialKey)
}

/// One generic-password item per sign-in under `<bundle id>.browser-http-auth`,
/// accessible after first unlock, this device only. Blocking Keychain calls:
/// callers run it off the main actor.
nonisolated struct KeychainHTTPCredentialStore: BrowserHTTPCredentialStoring {
    let service: String

    static var standard: KeychainHTTPCredentialStore {
        KeychainHTTPCredentialStore(service: "\(Bundle.main.bundleIdentifier ?? "com.cmuxterm.app").browser-http-auth")
    }

    private func base(_ key: BrowserHTTPCredentialKey) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key.account]
    }

    func login(for key: BrowserHTTPCredentialKey) -> BrowserHTTPRememberedLogin? {
        var query = base(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(BrowserHTTPRememberedLogin.self, from: data)
    }

    func save(_ login: BrowserHTTPRememberedLogin, for key: BrowserHTTPCredentialKey) {
        guard let data = try? JSONEncoder().encode(login) else { return }
        if SecItemUpdate(base(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = base(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "cmux sign-in for \(key.host)"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func forget(_ key: BrowserHTTPCredentialKey) {
        SecItemDelete(base(key) as CFDictionary)
    }
}

/// The store for tests and previews.
nonisolated final class InMemoryHTTPCredentialStore: BrowserHTTPCredentialStoring {
    private let logins = Mutex<[BrowserHTTPCredentialKey: BrowserHTTPRememberedLogin]>([:])

    func login(for key: BrowserHTTPCredentialKey) -> BrowserHTTPRememberedLogin? { logins.withLock { $0[key] } }
    func save(_ login: BrowserHTTPRememberedLogin, for key: BrowserHTTPCredentialKey) { logins.withLock { $0[key] = login } }
    func forget(_ key: BrowserHTTPCredentialKey) { _ = logins.withLock { $0.removeValue(forKey: key) } }
}

/// What a sign-in does with the store (pure rules; the tab runs the I/O).
nonisolated struct BrowserHTTPSignInMemory: Sendable {
    let store: any BrowserHTTPCredentialStoring
    let offTheRecord: Bool

    /// The remembered login to use without asking: first try only.
    func remembered(_ key: BrowserHTTPCredentialKey, failures: Int) -> BrowserHTTPRememberedLogin? {
        guard !offTheRecord, failures == 0 else { return nil }
        return store.login(for: key)
    }

    /// After the user answers: a checked Remember saves, an unchecked one
    /// forgets what was saved for that server. Off the record: nothing.
    func record(_ response: BrowserPromptResponse, for key: BrowserHTTPCredentialKey) {
        guard !offTheRecord, case .credentials(let user, let password, let remember) = response else { return }
        if remember {
            store.save(BrowserHTTPRememberedLogin(user: user, password: password), for: key)
        } else {
            store.forget(key)
        }
    }
}
