import Foundation

/// Where ``MobileHostMacIdentityStore`` keeps the identity's private scalar before its 0600 file: the login
/// Keychain on macOS (``MobileHostMacIdentityStore/loginKeychain(service:)``), a fake in tests.
protocol MobileHostIdentitySecretSlot: Sendable {
    /// The stored scalar; nil when there is none or the slot refused to read it without asking.
    func read() -> Data?
    /// Stores `privateKey`; false when the slot refused it (the store writes the file instead).
    func add(_ privateKey: Data) -> Bool
}

extension MobileHostMacIdentityStore {
    /// The login Keychain's slot for `service`; nil where there is no login Keychain (Linux), so the store keeps
    /// the file alone there, as it does when the Keychain refuses.
    static func loginKeychain(service: String) -> (any MobileHostIdentitySecretSlot)? {
        #if canImport(Security)
        MobileHostLoginKeychain(service: service)
        #else
        nil
        #endif
    }
}
