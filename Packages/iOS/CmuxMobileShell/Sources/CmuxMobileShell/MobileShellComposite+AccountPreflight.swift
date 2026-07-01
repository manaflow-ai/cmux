internal import CMUXMobileCore

extension MobileShellComposite {
    /// The account-binding preflight for a scanned/pasted pairing code: decide,
    /// before any route is dialed, whether the ticket's owner identity can
    /// belong to the signed-in user. Pure and unit-tested; the call site only
    /// supplies the live identity.
    ///
    /// Precedence mirrors the QR grammar (#6028): when the ticket carries the
    /// opaque Stack user id binding (`ub`), that id must equal the phone's —
    /// the email is never consulted, so a QR cannot be softened by stamping a
    /// matching email next to a foreign id. Legacy tickets without `ub` fall
    /// back to the email comparison. Unknown local identity (signed out or
    /// still restoring) returns `nil` and leaves rejection to the host's
    /// Stack-token verification.
    ///
    /// `isDevelopmentAuthEnvironment` names the channel the phone's user id
    /// belongs to: a development-project id can never equal the production id
    /// a release Mac stamps into its QR, so on a dev-channel build an id
    /// mismatch is reported as ``MobilePairingFailureCategory/authEnvironmentMismatch``
    /// (the truthful "dev build vs release Mac" explanation) instead of
    /// ``MobilePairingFailureCategory/authFailed``'s "check your email" copy
    /// (https://github.com/manaflow-ai/cmux/issues/7145). Production builds
    /// keep the #6028 behavior unchanged.
    static func emailFailure(
        for ticket: CmxAttachTicket,
        actualUserID: String?,
        actualEmail: String?,
        isDevelopmentAuthEnvironment: Bool
    ) -> MobilePairingFailureCategory? {
        if let expectedUserID = Self.mobileShellNormalizedNonEmpty(ticket.macUserID) {
            guard let actualUserID = Self.mobileShellNormalizedNonEmpty(actualUserID) else { return nil }
            guard actualUserID == expectedUserID else {
                return isDevelopmentAuthEnvironment ? .authEnvironmentMismatch : .authFailed
            }
            return nil
        }
        guard let actual = Self.mobileShellNormalizedEmail(actualEmail) else { return nil }
        if let expected = Self.mobileShellNormalizedEmail(ticket.macUserEmail) {
            guard actual == expected else {
                return .emailMismatch(expected: expected, actual: actual)
            }
            return nil
        }
        return nil
    }
}
