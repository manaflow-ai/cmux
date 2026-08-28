/// The Mac-local account, app, and namespace scope owning one allowlist store.
///
/// Entries recorded under one scope never authorize another: the store's
/// persisted record carries a digest of these fields, and a mismatch on load
/// is treated as another owner's data and dropped.
public struct CmxIrohPairedPeerAllowlistScope: Equatable, Sendable {
    /// The authenticated account that owns the current host binding.
    public let accountID: String

    /// The exact Mac build namespace sent to every broker request.
    public let clientNamespace: String

    /// The current app-instance UUID; a reinstall starts an empty allowlist.
    public let appInstanceID: String

    /// Creates the allowlist ownership scope for the active host lifecycle.
    ///
    /// - Parameters:
    ///   - accountID: The authenticated account that owns the host binding.
    ///   - clientNamespace: The installed Mac bundle namespace.
    ///   - appInstanceID: The current app-instance UUID.
    public init(
        accountID: String,
        clientNamespace: String,
        appInstanceID: String
    ) {
        self.accountID = accountID
        self.clientNamespace = clientNamespace
        self.appInstanceID = appInstanceID
    }
}
