#if !canImport(Security)
public import Foundation

/// Where no Keychain exists (Linux), relay capabilities have no protected
/// store: every call throws `errSecNotAvailable`, never an unprotected
/// fallback. Callers that run there inject their own store.
public actor CmxIrohKeychainCredentialStore: CmxIrohSecureCredentialStoring {
    /// Takes the Keychain store's parameters so callers compile unchanged.
    public init(
        service: String = "com.cmuxterm.iroh.relay-credentials.v1",
        accessGroup: String? = nil,
        legacyService: String? = nil
    ) {}

    public func read(account: String) throws -> Data? {
        throw Self.unavailable
    }

    public func write(
        _ data: Data,
        account: String,
        accessibility: CmxIrohSecureCredentialAccessibility
    ) throws {
        throw Self.unavailable
    }

    public func delete(account: String) throws {
        throw Self.unavailable
    }

    public func deleteAll() throws {
        throw Self.unavailable
    }

    /// Security.framework's `errSecNotAvailable`: no Keychain is available.
    private static let unavailable = CmxIrohKeychainCredentialStoreError(status: -25_291)
}
#endif
