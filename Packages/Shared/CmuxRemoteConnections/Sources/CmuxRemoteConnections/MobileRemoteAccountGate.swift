/// The authenticated cmux account identity supplied by the app auth coordinator.
///
/// This value authorizes an app-level connection attempt only. It does not
/// replace SSH host authentication, vault membership, or device enrollment.
public struct MobileRemoteAuthenticatedAccount: Equatable, Hashable, Sendable {
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

/// Account lifecycle boundary shared by all remote carriers.
///
/// The iOS composition root updates this actor from the authenticated auth
/// coordinator lifecycle. SSH, Mosh, ET, and cmux protocol owners must call
/// requireAccount immediately before reading credentials or opening a remote
/// socket. Clearing the account invalidates future setup; an existing transport
/// must separately observe the auth lifecycle and close itself.
public actor MobileRemoteAccountGate {
    private var account: MobileRemoteAuthenticatedAccount?

    /// Creates a signed-out gate.
    public init() {}

    /// Publishes the current authenticated account from the app auth owner.
    ///
    /// - Parameters:
    ///   - accountID: The auth coordinator's current user ID.
    ///   - sessionGeneration: Monotonic auth session generation.
    /// - Throws: Invalid-account when the auth bridge supplies malformed data.
    public func setAuthenticatedAccount(
        accountID: String,
        sessionGeneration: UInt64
    ) throws {
        account = try MobileRemoteAuthenticatedAccount(
            accountID: accountID, sessionGeneration: sessionGeneration
        )
    }

    /// Clears the gate on sign-out, account switch, or device revocation.
    public func clear() {
        account = nil
    }

    /// Returns the current authenticated account or fails closed.
    ///
    /// - Throws: Authentication-required when no account is active.
    public func requireAccount() throws -> MobileRemoteAuthenticatedAccount {
        guard let account else {
            throw MobileRemoteAccountGateError.authenticationRequired
        }
        return account
    }
}
