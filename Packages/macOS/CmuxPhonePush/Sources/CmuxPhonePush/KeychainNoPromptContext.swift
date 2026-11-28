#if canImport(Security)
import Foundation
import LocalAuthentication
import Security

/// Keychain queries that fail instead of showing UI: the query carries an `LAContext` with
/// `interactionNotAllowed`, so a data-protection Keychain call that would ask answers
/// `errSecInteractionNotAllowed`. It does not reach the macOS login (file-based) Keychain.
enum KeychainNoPromptContext {
    /// `query` with a context that refuses user interaction.
    static func applied(to query: [String: Any]) -> [String: Any] {
        var query = query
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }
}
#endif
