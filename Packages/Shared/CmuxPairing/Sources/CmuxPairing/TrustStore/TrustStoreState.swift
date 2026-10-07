public import CmuxMobileWire

/// The confirmed mirror of `trust:<user>` (b6-pairing.md section 6). Written
/// only from owner snapshots and events, never optimistically.
public struct TrustStoreState: Hashable, Sendable, Codable {
    public var devices: [String: TrustDevice]
    /// Keyed `<host>/<install>`.
    public var guests: [String: TrustGuest]
    /// Keyed by offer id.
    public var requests: [String: TrustRequest]
    /// Keyed `<host>/<install>`.
    public var remote: [String: TrustRemote]

    public init(devices: [String: TrustDevice] = [:], guests: [String: TrustGuest] = [:],
                requests: [String: TrustRequest] = [:], remote: [String: TrustRemote] = [:]) {
        self.devices = devices
        self.guests = guests
        self.requests = requests
        self.remote = remote
    }

    public static func pairKey(host: String, install: String) -> String { "\(host)/\(install)" }

    /// Decodes a snapshot's `state`.
    public init(snapshot state: JSONValue) throws {
        self = try state.decode(as: TrustStoreState.self)
    }

    /// Applies one owner event, mirroring the backend reducer
    /// (`backend/apps/api/src/domains/user-trust.ts`). Unknown ops are ignored
    /// (additive within v1); a malformed event throws so the caller resyncs.
    public mutating func apply(_ event: EventFrame) throws {
        let p = event.params
        requests = requests.filter { $0.value.expiresAt > event.at }
        switch event.op {
        case "trust.key.set":
            let cert = try p.require("cert", as: LinkCertificate.self)
            let kind = try p.require("kind", as: String.self)
            let name = try p.require("name", as: String.self)
            let platform = try p.require("platform", as: String.self)
            let publicKey = try p.require("public_jwk", as: InstallPublicKey.self)
            var device = devices[cert.install]
                ?? TrustDevice(install: cert.install, kind: kind, name: name, platform: platform, publicKey: publicKey,
                               certs: TrustDeviceCerts(), updatedAt: event.at)
            device.kind = kind
            device.name = name
            device.platform = platform
            device.publicKey = publicKey
            if let host = p["host"]?.stringValue { device.host = host }
            device.certs[cert.purpose] = cert
            device.updatedAt = event.at
            devices[cert.install] = device
        case "trust.install.revoked":
            let install = try p.require("install", as: String.self)
            devices[install] = nil
            remote = remote.filter { $0.value.install != install }
        case "trust.request.add":
            var request = try p.decode(as: TrustRequest.self)
            request.at = event.at
            requests[request.offerID] = request
        case "trust.request.remove":
            requests[try p.require("offer_id", as: String.self)] = nil
        case "trust.guest.add":
            var guest = try p.decode(as: TrustGuest.self)
            guest.acceptedAt = event.at
            requests[guest.offerID] = nil
            guests[Self.pairKey(host: guest.host, install: guest.device.install)] = guest
        case "trust.guest.remove":
            guests[Self.pairKey(host: try p.require("host", as: String.self), install: try p.require("install", as: String.self))] = nil
        case "trust.remote.add":
            var entry = try p.decode(as: TrustRemote.self)
            entry.acceptedAt = event.at
            remote[Self.pairKey(host: entry.host, install: entry.install)] = entry
        case "trust.remote.remove":
            remote[Self.pairKey(host: try p.require("host", as: String.self), install: try p.require("install", as: String.self))] = nil
        default:
            break
        }
    }
}
