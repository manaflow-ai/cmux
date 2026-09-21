import Foundation

/// The authenticated cmux account identity supplied by the app auth coordinator.
///
/// This value authorizes an app-level connection attempt only. It does not
/// replace SSH host authentication, vault membership, or device enrollment.
public struct MobileRemoteAuthenticatedAccount: Equatable, Hashable, Sendable {
    /// Local capability identity; a clear/re-enroll cannot revive an old snapshot.
    let capabilityID = UUID()

    /// Stable cmux account identifier.
    public let accountID: String
    /// Authenticated session generation, changed after reauthentication.
    public let sessionGeneration: UInt64

    init(accountID: String, sessionGeneration: UInt64) throws {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              accountID.utf8.count <= 256,
              !accountID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MobileRemoteAccountGateError.invalidAccount
        }
        self.accountID = accountID
        self.sessionGeneration = sessionGeneration
    }
}
