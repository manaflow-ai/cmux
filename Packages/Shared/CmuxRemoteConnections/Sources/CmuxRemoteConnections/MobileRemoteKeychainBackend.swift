import Foundation

/// Async Security backend used by ``MobileRemoteKeychainSecretStore``.
///
/// This protocol is internal to the package's composition boundary so tests
/// can model locked, cancelled, and malformed Keychain responses without
/// touching a user's real credential store.
protocol MobileRemoteKeychainBackend: Sendable {
    func insert(
        value: Data,
        scope: MobileRemoteSecretScope,
        protection: MobileRemoteSecretProtection
    ) async throws

    func read(
        scope: MobileRemoteSecretScope,
        interaction: MobileRemoteSecretInteraction
    ) async throws -> Data

    func updateValue(
        value: Data,
        scope: MobileRemoteSecretScope,
        interaction: MobileRemoteSecretInteraction
    ) async throws

    func delete(
        scope: MobileRemoteSecretScope,
        interaction: MobileRemoteSecretInteraction
    ) async throws
}
