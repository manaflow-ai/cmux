#if canImport(Security)
import Foundation
import LocalAuthentication
import os
import Security

/// The identity's slot in the login Keychain: a generic password of `service`, account `identity`, this device
/// only. It never shows Keychain UI: an item this build may not read without asking (a re-signed app) reads
/// as nil, with a log line, and the store falls back to its file.
struct MobileHostLoginKeychain: MobileHostIdentitySecretSlot {
    let service: String

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mobile.identity")

    /// A context that fails instead of showing Keychain UI.
    private static func noPrompt() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "identity"]
    }

    func read() -> Data? {
        var item: CFTypeRef?
        let search = query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                                    kSecUseAuthenticationContext as String: Self.noPrompt()]) { $1 }
        // SAFETY: SecItemCopyMatching stores at most one +1 CFTypeRef, which ARC then owns, into `item`, a local
        // live for the call.
        let status = unsafe SecItemCopyMatching(search as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Self.logger.error("iPhone host identity: Keychain read refused (\(status, privacy: .public)); using the file store")
            }
            return nil
        }
        return item as? Data
    }

    func add(_ privateKey: Data) -> Bool {
        let add = query.merging([kSecValueData as String: privateKey,
                                 kSecUseAuthenticationContext as String: Self.noPrompt(),
                                 kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                 kSecAttrLabel as String: "cmux iPhone host identity"]) { $1 }
        // SAFETY: with a nil result pointer SecItemAdd writes nothing back.
        return unsafe SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
#endif
