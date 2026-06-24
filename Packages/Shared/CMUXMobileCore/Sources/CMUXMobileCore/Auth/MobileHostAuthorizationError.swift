/// The reasons the mobile host can reject a Stack-authorized request.
///
/// Lifted byte-faithfully from the legacy `MobileHostAuthorizationError` declared
/// inside `MobileHostService.swift`. Thrown by ``MobileHostAccountAuthorizer`` and
/// the host's Stack verification path, and matched (`catch .accountMismatch`) where
/// the host maps a same-account failure to its distinct client-facing code. A pure
/// `Sendable` value enum so it can cross the verifier actor boundary.
public enum MobileHostAuthorizationError: Error, Sendable {
    /// The request carried no Stack access token.
    case missingStackTokens
    /// The Stack token verified but resolved to no usable user.
    case invalidStackUser
    /// No user is signed in on this Mac to authorize against.
    case missingLocalUser
    /// The Stack token belongs to a different account than the Mac owner.
    case accountMismatch
    /// Stack verification did not complete within the allowed window.
    case verificationTimedOut
}
