/// Same-account authorization decisions for the mobile host data plane.
///
/// Pure `String`-over-`String` policy with no stored state, no `MainActor`, and no
/// god-object reach: it only normalizes identifiers/tokens and compares them.
///
/// Replaces the legacy caseless namespace-enums `MobileHostAuthorizationPolicy` and
/// (DEBUG) `MobileHostDevStackAuthPolicy`, which were called as `Type.staticMethod(...)`.
/// Per the refactor conventions a static-only namespace is folded into a real value
/// type with instance methods; ``normalizedUserID(_:)`` / ``normalizedToken(_:)`` are
/// now private members. Construct one (`MobileHostAccountAuthorizer()`) and call the
/// instance methods at the use site.
public struct MobileHostAccountAuthorizer: Sendable {
    /// Creates an authorizer. Stateless; every instance is interchangeable.
    public init() {}

    /// Throws unless a user is signed in on this Mac and the remote Stack user
    /// matches that signed-in user after whitespace normalization.
    ///
    /// - Throws: ``MobileHostAuthorizationError/missingLocalUser`` when no local
    ///   user is signed in, or ``MobileHostAuthorizationError/accountMismatch``
    ///   when the remote user differs from the local one.
    public func authorizeStackUserID(localUserID: String?, remoteUserID: String?) throws {
        guard let localUserID = normalizedUserID(localUserID) else {
            throw MobileHostAuthorizationError.missingLocalUser
        }
        guard normalizedUserID(remoteUserID) == localUserID else {
            throw MobileHostAuthorizationError.accountMismatch
        }
    }

    private func normalizedUserID(_ value: String?) -> String? {
        value?.mobileTrimmedNonEmpty
    }
}

#if DEBUG
extension MobileHostAccountAuthorizer {
    /// The trimmed dev Stack token, or `nil` when it is empty after trimming.
    ///
    /// DEBUG-only: matches the legacy `MobileHostDevStackAuthPolicy.normalizedToken`.
    public func normalizedDevToken(_ token: String?) -> String? {
        normalizedToken(token)
    }

    /// Whether a provided dev Stack token matches the accepted dev token, after
    /// whitespace normalization. `false` whenever no accepted token is configured.
    ///
    /// DEBUG-only: matches the legacy `MobileHostDevStackAuthPolicy.authorize`.
    public func authorizeDevStackToken(providedToken: String, acceptedToken: String?) -> Bool {
        guard let acceptedToken = normalizedToken(acceptedToken) else {
            return false
        }
        return normalizedToken(providedToken) == acceptedToken
    }

    private func normalizedToken(_ token: String?) -> String? {
        token?.mobileTrimmedNonEmpty
    }
}
#endif
