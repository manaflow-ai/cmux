import Foundation

/// Failure reasons raised while authorizing a mobile data-plane request against
/// the Mac owner's signed-in Stack account.
///
/// Thrown by the app-side Stack-auth verifier and the same-account policy check;
/// the app's authorization gate maps `accountMismatch` to a distinct wire error
/// so clients can drive a re-authentication flow into the correct account.
public enum MobileHostAuthorizationError: Error {
    /// The request carried no Stack access token.
    case missingStackTokens
    /// The presented Stack token did not resolve to a usable Stack user ID.
    case invalidStackUser
    /// No Stack user is currently signed in on this Mac.
    case missingLocalUser
    /// The presented Stack token belongs to a different account than the one
    /// signed in on this Mac.
    case accountMismatch
    /// The Stack verification network lookup exceeded its timeout.
    case verificationTimedOut
}
