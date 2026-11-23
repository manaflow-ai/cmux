internal import LocalAuthentication
internal import Security

/// Keychain queries that fail instead of showing UI, for the data-protection Keychain and access-control
/// items: the query carries an `LAContext` with `interactionNotAllowed`, so a call that would ask answers
/// `errSecInteractionNotAllowed`. It does not reach the login (file-based) Keychain; calls there run inside
/// ``LoginKeychain/withoutUI(_:)``.
public struct KeychainNoPromptContext {
    public init() {}

    /// `query` with a context that refuses user interaction.
    public static func applied(to query: [String: Any]) -> [String: Any] {
        var query = query
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }
}
