#if !canImport(Security)
public import Foundation

/// Where no Keychain exists (Linux), EndpointID secrets have no protected
/// store: every call throws `errSecNotAvailable`, never an unprotected
/// fallback. Callers that run there inject their own store.
public actor CmxIrohKeychainIdentityStore: CmxIrohSecureIdentityStoring {
    /// Takes the Keychain store's parameters so callers compile unchanged.
    public init(
        service: String = "com.cmuxterm.iroh.endpoint-identity.v1",
        accessGroup: String? = nil,
        legacyService: String? = nil
    ) {}

    public func read(account: String) async throws -> Data? {
        throw Self.unavailable
    }

    public func write(_ data: Data, account: String) async throws {
        throw Self.unavailable
    }

    public func delete(account: String) async throws {
        throw Self.unavailable
    }

    public func deleteAll() async throws {
        throw Self.unavailable
    }

    /// Generates one Ed25519 secret from the system's cryptographic randomness.
    public static func randomSecretBytes() throws -> Data {
        guard let bytes = CmxIrohSystemRandomByteGenerator.systemRandomBytes(count: 32) else {
            throw CmxIrohIdentityRepositoryError.randomGenerationFailed(errSecNotAvailable)
        }
        return bytes
    }

    /// Security.framework's `errSecNotAvailable`: no Keychain is available.
    private static let errSecNotAvailable: Int32 = -25_291
    private static let unavailable = CmxIrohKeychainIdentityStoreError(status: errSecNotAvailable)
}
#endif
