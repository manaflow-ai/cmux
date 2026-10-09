public import CmuxLinkDirect
public import CmuxLinkWebRTC
public import CmuxLinkWG
public import CmuxMobileLink
public import CmuxMobileWire
public import Foundation

/// This install's keys for every carrier (b6-pairing.md section 2): the
/// install key signs `hello.auth` and WebRTC fingerprints (Secure Enclave on
/// device), the X25519 keys its trust store certs name prove B4 and B3.
public struct MobileDeviceCredentials: Sendable {
    /// The key id hello proofs carry: the trust store holds one install key
    /// per install, so the id names that key (the Mac's mirror uses the same).
    public static let installKeyID = "install"

    public var signer: any MobileDeviceSigner
    public var client: HelloClient
    public var direct: DirectIdentity
    /// Nil: no WebRTC (an install key that cannot sign synchronously).
    public var webrtc: (any WebRTCIdentity)?
    /// Nil: no published `wg` cert, so no V2.
    public var wireGuard: WireGuardPrivateKey?

    public init(signer: any MobileDeviceSigner, client: HelloClient, direct: DirectIdentity,
                webrtc: (any WebRTCIdentity)? = nil, wireGuard: WireGuardPrivateKey? = nil) {
        self.signer = signer
        self.client = client
        self.direct = direct
        self.webrtc = webrtc
        self.wireGuard = wireGuard
    }

    /// Enables B3 with this install's raw X25519 `wg` key (the one its
    /// published `wg` cert names; Macs authorize nothing else).
    public mutating func useWireGuardKey(rawRepresentation: Data) throws {
        wireGuard = try WireGuardPrivateKey(rawRepresentation: rawRepresentation)
    }
}
