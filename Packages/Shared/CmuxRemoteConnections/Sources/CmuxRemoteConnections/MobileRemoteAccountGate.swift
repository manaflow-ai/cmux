import Foundation

/// Account lifecycle boundary shared by all remote carriers.
///
/// The iOS composition root updates this actor from the authenticated auth
/// coordinator lifecycle. SSH, Mosh, ET, and cmux protocol owners must call
/// requireAccount immediately before reading credentials or opening a remote
/// socket. Clearing the account invalidates future setup; an existing transport
/// must separately observe the auth lifecycle and close itself.
public actor MobileRemoteAccountGate {
    private var account: MobileRemoteAuthenticatedAccount?

    private let validate: @Sendable (MobileRemoteAuthenticatedAccount) async throws -> Void

    /// Creates a signed-out gate requiring live authority validation.
    /// - Parameter validate: Checks the auth owner directly; a cached observer
    ///   is insufficient for production sign-out invalidation.
    public init(validate: @escaping @Sendable (MobileRemoteAuthenticatedAccount) async throws -> Void) {
        self.validate = validate
    }

    /// Package-test fixture only; app consumers must inject the auth owner.
    init() { validate = { _ in } }

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
        if account?.accountID == accountID, account?.sessionGeneration == sessionGeneration { return }
        account = nil
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
    public func requireAccount() async throws -> MobileRemoteAuthenticatedAccount {
        guard let account else {
            throw MobileRemoteAccountGateError.authenticationRequired
        }
        try Task.checkCancellation()
        try await validate(account)
        try Task.checkCancellation()
        guard self.account == account else {
            throw MobileRemoteAccountGateError.authenticationRequired
        }
        return account
    }

    /// Revalidates a captured account across suspended connection work.
    /// - Parameter expected: Account returned before the operation began.
    /// - Throws: Authentication-required when account or session authority changed.
    public func requireCurrent(_ expected: MobileRemoteAuthenticatedAccount) async throws {
        guard try await requireAccount() == expected else {
            throw MobileRemoteAccountGateError.authenticationRequired
        }
    }
}
