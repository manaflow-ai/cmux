import Foundation

/// Persists and validates the stable installation identifier used by v2.
public struct V2InstallationIDStore: Sendable {
    private static let serviceSuffix = ".cmux-iroh-v2.installation"
    private static let account = "device-id"

    private let keychain: V2KeychainStore

    /// Creates an installation-ID store in the app's dedicated keychain service.
    /// - Parameters:
    ///   - applicationNamespace: The app bundle's explicit keychain namespace.
    ///   - accessGroup: The optional signing-entitled keychain group.
    ///   - access: The Security adapter; tests inject an in-memory adapter.
    public init(
        applicationNamespace: String,
        accessGroup: String? = nil,
        access: any V2KeychainAccess = V2SystemKeychainAccess()
    ) {
        keychain = V2KeychainStore(
            service: applicationNamespace + Self.serviceSuffix,
            accessGroup: accessGroup,
            access: access
        )
    }

    /// Loads the existing UUID or creates one for this installation.
    ///
    /// The returned string preserves the exact UTF-8 bytes stored in the
    /// keychain. Validation accepts any UUID spelling accepted by Foundation,
    /// so migrating an older uppercase value never rotates the identity.
    /// - Returns: The validated, stable installation UUID.
    /// - Throws: ``V2ControlFailure/persistenceFailed`` for missing, malformed,
    ///   or unavailable keychain data.
    public func loadOrCreate() throws -> String {
        let candidate = UUID().uuidString.lowercased()
        let data = try keychain.loadOrCreate(
            account: Self.account,
            candidate: Data(candidate.utf8),
            validate: { data in _ = try Self.decode(data) }
        )
        return try Self.decode(data)
    }

    private static func decode(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8),
              UUID(uuidString: value) != nil else {
            throw V2ControlFailure.persistenceFailed
        }
        return value
    }
}
