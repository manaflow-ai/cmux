import CmuxMobileTransport
import Foundation
import Security

/// This phone's Noise key for its Cloud carriers: made once per account, kept in the Keychain
/// (this device only, after first unlock) beside the link identity, and removed on sign-out.
struct CloudCarrierKey {
    static func account(_ userID: String) -> String { "cloud-carrier.\(userID)" }

    /// One read-or-create at a time: two first dials (two machines at launch) never make two keys.
    private static let lock = NSLock()

    /// The account's key, made and stored the first time. A Keychain that is locked (before the
    /// first unlock) throws `keychain.locked`, which a later dial retries; one that can't be used
    /// at all (a missing entitlement, -34018, or another error) throws `keychain.unavailable`,
    /// which stops the dials and says so. Never a throwaway key.
    static func load(userID: String, store: any DeviceSecretStore = KeychainSecretStore(),
                     service: String = DeviceIdentity.defaultService,
                     newKey: () throws -> Data) throws -> Data {
        let account = account(userID)
        return try lock.withLock {
            do {
                if let stored = try store.read(service: service, account: account), stored.count == 32 { return stored }
            } catch {
                throw failure(error)
            }
            let key = try newKey()
            do {
                try store.write(key, service: service, account: account)
            } catch {
                throw failure(error)
            }
            return key
        }
    }

    /// A Keychain error as the dial's refusal: locked is retryable, anything else is not.
    static func failure(_ error: any Error) -> LinkError {
        if let failure = error as? KeychainSecretStore.Failure, failure.status == errSecInteractionNotAllowed {
            return LinkError(code: CloudCarrierDialer.keychainLocked, message: "the Keychain is locked until this iPhone is unlocked")
        }
        let status = (error as? KeychainSecretStore.Failure).map { " (\($0.status))" } ?? ""
        return LinkError(code: CloudCarrierDialer.keychainUnavailable, message: "the Keychain can't keep the Cloud key\(status)")
    }

    /// Sign-out: the key goes; the next sign-in makes a new one.
    static func forget(userID: String, store: any DeviceSecretStore = KeychainSecretStore(),
                       service: String = DeviceIdentity.defaultService) {
        lock.withLock { store.delete(service: service, account: account(userID)) }
    }
}
