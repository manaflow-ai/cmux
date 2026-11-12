import CmuxMobileTransport
import Foundation

/// This phone's Noise key for its Cloud carriers: made once per account, kept in the Keychain
/// (this device only, after first unlock) beside the link identity, and removed on sign-out.
struct CloudCarrierKey {
    static func account(_ userID: String) -> String { "cloud-carrier.\(userID)" }

    /// The account's key, made and stored the first time. A Keychain that can't be read now
    /// (before the first unlock) throws: a dial fails and retries, never with a throwaway key.
    static func load(userID: String, store: any DeviceSecretStore = KeychainSecretStore(),
                     service: String = DeviceIdentity.defaultService,
                     newKey: () throws -> Data) throws -> Data {
        let account = account(userID)
        do {
            if let stored = try store.read(service: service, account: account), stored.count == 32 { return stored }
        } catch {
            throw LinkError(code: "keychain", message: "the Keychain is locked")
        }
        let key = try newKey()
        try store.write(key, service: service, account: account)
        return key
    }

    /// Sign-out: the key goes; the next sign-in makes a new one.
    static func forget(userID: String, store: any DeviceSecretStore = KeychainSecretStore(),
                       service: String = DeviceIdentity.defaultService) {
        store.delete(service: service, account: account(userID))
    }
}
