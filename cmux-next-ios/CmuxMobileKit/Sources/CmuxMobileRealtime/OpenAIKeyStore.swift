import Foundation
import Observation
import Security

/// Where the user's OpenAI API key is kept.
public protocol OpenAIKeyStoring: Sendable {
    func load() -> String?
    func save(_ key: String) throws
    func delete() throws
}

/// The key in this iPhone's Keychain, one item per cmux account: a second
/// account signed in on the same phone never calls with the first one's key.
/// `AfterFirstUnlockThisDeviceOnly`: readable while the phone is locked (a
/// call that reconnects from the background), never synced or restored to
/// another device.
public struct KeychainOpenAIKeyStore: OpenAIKeyStoring {
    public static let service = "dev.cmux.mobile.openai-api-key"
    let account: String

    public init(accountID: String) {
        account = accountID
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    public func load() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ key: String) throws {
        let data = Data(key.utf8)
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(update) { $1 }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    public struct KeychainError: Error, Equatable {
        public let status: OSStatus
    }
}

/// The key for the signed-in account as Settings and the call screen see it:
/// whether there is one, its masked form, the newest check against OpenAI.
@MainActor
@Observable
public final class OpenAIKeyModel {
    /// The signed-in account's model; the shell sets the account.
    public static let shared = OpenAIKeyModel()

    public private(set) var hasKey = false
    /// "sk-…AB12": enough to tell keys apart, never the key.
    public private(set) var maskedKey: String?
    /// The newest check of the stored key or a key being added.
    public private(set) var check: OpenAIKeyCheck?
    public private(set) var isChecking = false
    /// The account the key belongs to; nil while signed out.
    public private(set) var accountID: String?

    @ObservationIgnored private var store: (any OpenAIKeyStoring)?
    @ObservationIgnored private let makeStore: @Sendable (String) -> any OpenAIKeyStoring
    @ObservationIgnored private let verifier: OpenAIKeyVerifier

    public init(makeStore: @escaping @Sendable (String) -> any OpenAIKeyStoring = { KeychainOpenAIKeyStore(accountID: $0) },
                verifier: OpenAIKeyVerifier = OpenAIKeyVerifier()) {
        self.makeStore = makeStore
        self.verifier = verifier
    }

    /// Selects the signed-in account (nil after sign-out) and reads its key.
    public func selectAccount(_ accountID: String?) {
        guard accountID != self.accountID else { return }
        self.accountID = accountID
        store = accountID.map(makeStore)
        check = nil
        refresh()
    }

    /// Whether `candidate` looks like an OpenAI key (Settings' Save button).
    public func isPlausible(_ candidate: String) -> Bool {
        OpenAIKeyFormat.isPlausible(candidate.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The stored key, read when a call starts (never kept in memory between calls).
    public func key() -> String? { store?.load() }

    /// Checks `candidate` with OpenAI and stores it unless OpenAI refused it.
    /// A key that could not be checked (offline) is stored; the call reports
    /// a problem when it connects.
    /// - Returns: The check's outcome.
    @discardableResult
    public func add(_ candidate: String, model: String) async -> OpenAIKeyCheck {
        let key = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OpenAIKeyFormat.isPlausible(key) else {
            check = .malformed
            return .malformed
        }
        // The account and its store as of now: a sign-out or switch during the check
        // must not put this key in another account's Keychain item.
        let account = accountID
        let target = store
        isChecking = true
        let outcome = await verifier.check(key: key, model: model)
        isChecking = false
        guard account == accountID else { return outcome }
        check = outcome
        guard outcome.allowsSaving, let target else { return outcome }
        do { try target.save(key) } catch { check = .notSaved }
        refresh()
        return check ?? outcome
    }

    /// Checks the stored key again (Settings' Check Key).
    public func recheck(model: String) async {
        guard let key = key() else { return }
        let account = accountID
        isChecking = true
        let outcome = await verifier.check(key: key, model: model)
        isChecking = false
        if account == accountID { check = outcome }
    }

    #if DEBUG
    /// DEBUG: stores a key without checking it (the scripted demo call's placeholder).
    public func storeForDemo(_ key: String) {
        try? store?.save(key)
        refresh()
    }
    #endif

    public func remove() {
        try? store?.delete()
        check = nil
        refresh()
    }

    private func refresh() {
        let key = store?.load()
        hasKey = key != nil
        maskedKey = key.map(OpenAIKeyFormat.masked)
    }
}

/// What OpenAI said about a key.
public enum OpenAIKeyCheck: Sendable, Equatable {
    /// The key works and can use the model.
    case valid
    /// Not an OpenAI key (`sk-…`).
    case malformed
    /// OpenAI refused it (401).
    case rejected
    /// The key works, but its project can't use the voice model (403/404).
    case modelUnavailable
    /// The account is out of credit or over its limits (429).
    case quota
    /// OpenAI could not be reached; the key was kept unchecked.
    case unreachable(String)
    /// The Keychain refused to store it.
    case notSaved

    var allowsSaving: Bool {
        switch self {
        case .valid, .modelUnavailable, .quota, .unreachable: true
        case .malformed, .rejected, .notSaved: false
        }
    }
}

/// Shape checks on a pasted key, before any network call.
struct OpenAIKeyFormat {
    static func isPlausible(_ key: String) -> Bool {
        key.hasPrefix("sk-") && key.count >= 20 && !key.contains(where: \.isWhitespace)
    }

    static func masked(_ key: String) -> String {
        "sk-…" + String(key.suffix(4))
    }
}
