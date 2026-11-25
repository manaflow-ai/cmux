#if !canImport(Security)
public import Foundation

// Platforms without Security.framework (the Linux package lane) have no Keychain.
// These stand-ins keep the Keychain stores' names and initializers, so the
// defaults that name them still compile, and refuse every operation with
// errSecUnimplemented. Callers there inject their own secure store.
private let keychainUnimplemented: Int32 = -4

/// Keychain credential storage where no Keychain exists: every call throws.
public actor CmxIrohKeychainCredentialStore: CmxIrohSecureCredentialStoring {
    public init(
        service: String = "com.cmuxterm.iroh.relay-credentials.v1",
        accessGroup: String? = nil,
        legacyService: String? = nil
    ) {}

    public func read(account: String) throws -> Data? {
        throw CmxIrohKeychainCredentialStoreError(status: keychainUnimplemented)
    }

    public func write(
        _ data: Data,
        account: String,
        accessibility: CmxIrohSecureCredentialAccessibility
    ) throws {
        throw CmxIrohKeychainCredentialStoreError(status: keychainUnimplemented)
    }

    public func delete(account: String) throws {
        throw CmxIrohKeychainCredentialStoreError(status: keychainUnimplemented)
    }

    public func deleteAll() throws {
        throw CmxIrohKeychainCredentialStoreError(status: keychainUnimplemented)
    }
}

/// Keychain identity storage where no Keychain exists: every call throws.
public actor CmxIrohKeychainIdentityStore: CmxIrohSecureIdentityStoring {
    public init(
        service: String = "com.cmuxterm.iroh.endpoint-identity.v1",
        accessGroup: String? = nil,
        legacyService: String? = nil
    ) {}

    public func read(account: String) async throws -> Data? {
        throw CmxIrohKeychainIdentityStoreError(status: keychainUnimplemented)
    }

    public func write(_ data: Data, account: String) async throws {
        throw CmxIrohKeychainIdentityStoreError(status: keychainUnimplemented)
    }

    public func delete(account: String) async throws {
        throw CmxIrohKeychainIdentityStoreError(status: keychainUnimplemented)
    }

    public func deleteAll() async throws {
        throw CmxIrohKeychainIdentityStoreError(status: keychainUnimplemented)
    }

    /// Generates one Ed25519 secret from the system CSPRNG.
    public static func randomSecretBytes() throws -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
#endif
