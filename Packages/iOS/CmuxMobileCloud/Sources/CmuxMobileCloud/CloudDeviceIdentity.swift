public import Foundation

/// This phone's identity on the user's cloud network: a stable fingerprint
/// plus its WireGuard key pair.
///
/// Minted once per install. A reinstall mints a new one and the control
/// plane rotates the tunnel in place under the new fingerprint.
public struct CloudDeviceIdentity: Sendable, Equatable {
    /// `ios-<uuid>`, the device fingerprint sent on enroll and attach.
    public var fingerprint: String
    /// The WireGuard key pair; only ``WireGuardKeyPair/publicKey`` travels.
    public var keyPair: WireGuardKeyPair

    /// Creates an identity from stored parts.
    public init(fingerprint: String, keyPair: WireGuardKeyPair) {
        self.fingerprint = fingerprint
        self.keyPair = keyPair
    }

    /// Mints a fresh identity.
    public static func mint() -> CloudDeviceIdentity {
        CloudDeviceIdentity(fingerprint: "ios-" + UUID().uuidString.lowercased(), keyPair: WireGuardKeyPair())
    }
}
