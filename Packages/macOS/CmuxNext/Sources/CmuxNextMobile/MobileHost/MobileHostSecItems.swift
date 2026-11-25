import CmuxNextCompat
import Foundation
import Security

/// The four Keychain calls the seal makes: the Security framework's, or a fake Keychain (tests).
/// `system` adds a no-UI context to every query; callers also run login-Keychain calls in
/// `LoginKeychain.withoutUI`, which that context does not reach.
struct MobileHostSecItems: Sendable {
    var copy: @Sendable (_ query: [String: Any]) -> (status: OSStatus, value: Data?)
    var update: @Sendable (_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    var add: @Sendable (_ attributes: [String: Any]) -> OSStatus
    var delete: @Sendable (_ query: [String: Any]) -> OSStatus

    static let system = MobileHostSecItems(
        copy: { query in
            var item: CFTypeRef?
            let status = SecItemCopyMatching(KeychainNoPromptContext.applied(to: query) as CFDictionary, &item)
            return (status, item as? Data)
        },
        update: { SecItemUpdate(KeychainNoPromptContext.applied(to: $0) as CFDictionary, $1 as CFDictionary) },
        add: { SecItemAdd(KeychainNoPromptContext.applied(to: $0) as CFDictionary, nil) },
        delete: { SecItemDelete(KeychainNoPromptContext.applied(to: $0) as CFDictionary) })
}
