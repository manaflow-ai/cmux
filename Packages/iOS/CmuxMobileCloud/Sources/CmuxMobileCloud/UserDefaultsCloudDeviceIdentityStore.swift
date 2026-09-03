public import Foundation

/// Identity store for an iOS Simulator process.
///
/// Unsigned simulator apps have no application-identifier entitlement, so
/// data-protection Keychain calls fail even on an unlocked simulated device
/// and ``KeychainCloudDeviceIdentityStore`` would report `.unavailable`
/// forever. The simulator therefore keeps the identity in its defaults domain.
/// Simulator only: the composition root selects this under
/// `targetEnvironment(simulator)`; physical devices always use the Keychain.
public final class UserDefaultsCloudDeviceIdentityStore: CloudDeviceIdentityStoring, @unchecked Sendable {
    private struct Payload: Codable {
        var fingerprint: String
        var privateKey: String
    }

    private let defaults: UserDefaults
    private let key: String

    /// Creates a store.
    /// - Parameters:
    ///   - defaults: The defaults domain; `.standard` in the app, a suite in tests.
    ///   - key: The defaults key holding the identity.
    public init(defaults: UserDefaults, key: String = "cmux.cloud.deviceIdentity.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func read() -> CloudDeviceIdentityReadResult {
        guard let data = defaults.data(forKey: key) else { return .absent }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let keyPair = WireGuardKeyPair(privateKey: payload.privateKey),
              !payload.fingerprint.isEmpty else {
            return .absent
        }
        return .found(CloudDeviceIdentity(fingerprint: payload.fingerprint, keyPair: keyPair))
    }

    public func write(_ identity: CloudDeviceIdentity) throws {
        let data = try JSONEncoder().encode(Payload(fingerprint: identity.fingerprint, privateKey: identity.keyPair.privateKey))
        defaults.set(data, forKey: key)
    }
}
