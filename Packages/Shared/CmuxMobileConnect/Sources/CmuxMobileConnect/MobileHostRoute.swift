public import CmuxLink
public import CmuxLinkDirect
public import CmuxLinkWebRTC
public import CmuxLinkWG
public import CmuxPairing
import CryptoKit
public import Foundation

/// How the phone may reach one trusted Mac: the keys pairing pinned for
/// every carrier and the direct endpoints known right now (synced direct
/// hosts, Bonjour results). Built from B6's trust store, never from the
/// network: a TXT record or an address only says where to dial, the keys say
/// who must answer.
public struct MobileHostRoute: Sendable, Hashable {
    public var hostID: String
    public var name: String
    /// B4: where to dial; every endpoint pins `directHostKey`.
    public var directEndpoints: [DirectEndpoint]
    public var directHostKey: DirectPublicKey?
    /// B2: the host install's P-256 key, bound to its DTLS fingerprint.
    public var webrtcHostKey: WebRTCPublicKey?
    /// B3: the host's WireGuard key.
    public var wireGuardHostKey: WireGuardPublicKey?

    public init(hostID: String, name: String, directEndpoints: [DirectEndpoint] = [], directHostKey: DirectPublicKey? = nil,
                webrtcHostKey: WebRTCPublicKey? = nil, wireGuardHostKey: WireGuardPublicKey? = nil) {
        self.hostID = hostID
        self.name = name
        self.directHostKey = directHostKey
        self.directEndpoints = directHostKey.map { key in directEndpoints.filter { $0.hostKey == key } } ?? []
        self.webrtcHostKey = webrtcHostKey
        self.wireGuardHostKey = wireGuardHostKey
    }

    /// The route for a Mac the trust store vouches for, dialing `targets`
    /// (each pinned to the Mac's verified `direct` key).
    public init?(trusted key: TrustedHostKey, targets: [DirectEndpoint.Target] = []) {
        guard let direct = DirectPublicKey(rawRepresentation: key.directKey) else { return nil }
        let webrtc = key.installKey?.signingKey.flatMap { WebRTCPublicKey(x963Representation: $0.x963Representation) }
        let wireGuard = key.wireGuardKey.flatMap(WireGuardPublicKey.init(rawRepresentation:))
        self.init(hostID: key.host, name: key.name,
                  directEndpoints: targets.map { DirectEndpoint(target: $0, hostKey: direct) },
                  directHostKey: direct, webrtcHostKey: webrtc, wireGuardHostKey: wireGuard)
    }

    /// The peer every carrier dials: the WebRTC and WireGuard pins ride the
    /// hints their default resolvers read; direct endpoints come from the
    /// route's plan (they change without a new client).
    public var peer: LinkPeer {
        var hints: [String: String] = [:]
        if let webrtcHostKey { hints.merge(WebRTCHintsResolver().hints(hostKey: webrtcHostKey)) { $1 } }
        if let wireGuardHostKey { hints.merge(WireGuardHintsResolver().hints(for: wireGuardHostKey)) { $1 } }
        return LinkPeer(hostID: hostID, hints: hints)
    }

    /// Whether `other` pins the same keys (same client) and only its
    /// endpoints or name may differ.
    public func pinsSameKeys(as other: MobileHostRoute) -> Bool {
        hostID == other.hostID && directHostKey == other.directHostKey && webrtcHostKey == other.webrtcHostKey
            && wireGuardHostKey == other.wireGuardHostKey
    }
}
