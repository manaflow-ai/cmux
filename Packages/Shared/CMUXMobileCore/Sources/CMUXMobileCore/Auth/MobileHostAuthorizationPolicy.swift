import Foundation

/// Same-account authorization check binding a remote Stack user ID to the Mac
/// owner's locally signed-in Stack user ID.
///
/// Pure string comparison: both IDs are trimmed of surrounding whitespace and an
/// empty result is treated as absent. Holds no state, so any instance behaves
/// identically.
public struct MobileHostAuthorizationPolicy: Sendable {
    public init() {}

    /// Throws `MobileHostAuthorizationError.missingLocalUser` when no user is
    /// signed in on this Mac, and `.accountMismatch` when `remoteUserID` does not
    /// resolve to the same non-empty Stack user ID as `localUserID`.
    public func authorizeStackUserID(localUserID: String?, remoteUserID: String?) throws {
        guard let localUserID = Self.normalizedUserID(localUserID) else {
            throw MobileHostAuthorizationError.missingLocalUser
        }
        guard Self.normalizedUserID(remoteUserID) == localUserID else {
            throw MobileHostAuthorizationError.accountMismatch
        }
    }

    private static func normalizedUserID(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
