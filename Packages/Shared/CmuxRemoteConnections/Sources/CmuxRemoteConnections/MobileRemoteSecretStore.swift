import Foundation

/// Async protocol for storing opaque connection secrets in a device Keychain.
///
/// The caller must obtain the scope's account identifier from the authenticated
/// cmux account session. This storage API intentionally does not create an
/// anonymous or installation-local scope.
public protocol MobileRemoteSecretStore: Sendable {
    /// Inserts a new exact scope with immutable OS protection policy.
    ///
    /// - Parameters:
    ///   - value: Secret bytes; never serialized by this API.
    ///   - scope: Account, vault, and item identity.
    ///   - protection: Access control applied only at insertion.
    /// - Throws: ``MobileRemoteSecretStoreError/itemAlreadyExists`` rather than upserting.
    func insert(
        _ value: MobileRemoteSecretValue,
        scope: MobileRemoteSecretScope,
        protection: MobileRemoteSecretProtection
    ) async throws

    /// Reads a secret, optionally allowing an explicitly explained OS prompt.
    ///
    /// - Parameters:
    ///   - scope: Exact account, vault, and item identity.
    ///   - interaction: Background reads must use ``MobileRemoteSecretInteraction/nonInteractive``.
    /// - Returns: Secret bytes only if the task remains uncancelled after Keychain access.
    func read(
        scope: MobileRemoteSecretScope,
        interaction: MobileRemoteSecretInteraction
    ) async throws -> MobileRemoteSecretValue

    /// Replaces only the value while preserving the existing Keychain ACL.
    ///
    /// - Parameters:
    ///   - value: Replacement secret bytes.
    ///   - scope: Exact account, vault, and item identity.
    ///   - interaction: Whether Security.framework may authenticate the update.
    func updateValue(
        _ value: MobileRemoteSecretValue,
        scope: MobileRemoteSecretScope,
        interaction: MobileRemoteSecretInteraction
    ) async throws

    /// Deletes exactly one scoped item and never issues a wildcard query.
    ///
    /// - Parameters:
    ///   - scope: Exact account, vault, and item identity.
    ///   - interaction: Whether Security.framework may authenticate the deletion.
    func delete(
        scope: MobileRemoteSecretScope,
        interaction: MobileRemoteSecretInteraction
    ) async throws
}

/// Actor-isolated Keychain secret store that never falls back to plaintext files.
public actor MobileRemoteKeychainSecretStore: MobileRemoteSecretStore {
    private let backend: any MobileRemoteKeychainBackend

    /// Creates a store using Security.framework and the exact signed namespace.
    ///
    /// - Parameter namespace: Access group and stable service identifier from the signed app.
    public init(namespace: MobileRemoteKeychainNamespace) {
        self.backend = MobileRemoteKeychainSecurity(namespace: namespace)
    }

    init(namespace: MobileRemoteKeychainNamespace, backend: any MobileRemoteKeychainBackend) {
        self.backend = backend
    }

    /// Inserts a value without changing an existing item's policy.
    public func insert(
        _ value: MobileRemoteSecretValue,
        scope: MobileRemoteSecretScope,
        protection: MobileRemoteSecretProtection
    ) async throws {
        try Task.checkCancellation()
        try await backend.insert(value: value.bytes, scope: scope, protection: protection)
        try Task.checkCancellation()
    }

    /// Reads a value and discards it if cancellation is observed before return.
    public func read(
        scope: MobileRemoteSecretScope,
        interaction: MobileRemoteSecretInteraction = .nonInteractive
    ) async throws -> MobileRemoteSecretValue {
        try Task.checkCancellation()
        try interaction.validate()
        let bytes = try await backend.read(scope: scope, interaction: interaction)
        try Task.checkCancellation()
        return MobileRemoteSecretValue(bytes: bytes)
    }

    /// Updates bytes while leaving the existing protection policy untouched.
    public func updateValue(
        _ value: MobileRemoteSecretValue,
        scope: MobileRemoteSecretScope,
        interaction: MobileRemoteSecretInteraction = .nonInteractive
    ) async throws {
        try Task.checkCancellation()
        try interaction.validate()
        try await backend.updateValue(
            value: value.bytes, scope: scope, interaction: interaction
        )
        try Task.checkCancellation()
    }

    /// Deletes exactly one item after validating any localized authentication reason.
    public func delete(
        scope: MobileRemoteSecretScope,
        interaction: MobileRemoteSecretInteraction = .nonInteractive
    ) async throws {
        try Task.checkCancellation()
        try interaction.validate()
        try await backend.delete(scope: scope, interaction: interaction)
        try Task.checkCancellation()
    }
}
