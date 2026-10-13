public import Foundation

/// What a Mac shows (as a QR code or a link) so a phone can pair with it.
///
/// The invitation carries a one-time WireGuard identity for the phone (the
/// bootstrap key) and a preshared key. The Mac admits that identity as a
/// peer that can reach only the enrollment port, for a few minutes. The
/// phone uses it once to send its own permanent public key over the tunnel;
/// the Mac then adds the permanent key and drops the bootstrap peer. The QR
/// code is the secret channel: anyone who reads it before it expires can
/// pair, as with any pairing code.
public struct PairingInvitation: Codable, Hashable, Sendable {
    public static let version = 1

    public var version: Int
    /// The Mac's display name ("Aziz's MacBook Pro").
    public var hostName: String
    /// Stable id of this Mac's pairing host (survives restarts).
    public var hostID: String
    /// The Mac's WireGuard public key.
    public var hostKey: WireGuardKey
    /// UDP endpoints to try, best first ("192.168.1.20:51888", "[fd7a::1]:51888").
    public var endpoints: [String]
    /// The phone's one-time private key and its tunnel address.
    public var bootstrapKey: WireGuardKey
    public var bootstrapAddress: String
    public var presharedKey: WireGuardKey
    /// The Mac's tunnel address.
    public var hostAddress: String
    /// Seconds since 1970 after which the Mac refuses this invitation.
    public var expiresAt: Double

    public init(hostName: String, hostID: String, hostKey: WireGuardKey, endpoints: [String],
                bootstrapKey: WireGuardKey, bootstrapAddress: String, presharedKey: WireGuardKey,
                hostAddress: String, expiresAt: Date) {
        version = Self.version
        self.hostName = hostName
        self.hostID = hostID
        self.hostKey = hostKey
        self.endpoints = endpoints
        self.bootstrapKey = bootstrapKey
        self.bootstrapAddress = bootstrapAddress
        self.presharedKey = presharedKey
        self.hostAddress = hostAddress
        self.expiresAt = expiresAt.timeIntervalSince1970
    }

    enum CodingKeys: String, CodingKey {
        case version = "v", hostName = "n", hostID = "id", hostKey = "hk", endpoints = "ep"
        case bootstrapKey = "bk", bootstrapAddress = "ba", presharedKey = "psk", hostAddress = "ha"
        case expiresAt = "exp"
    }

    public var expiry: Date { Date(timeIntervalSince1970: expiresAt) }

    /// The URL scheme the iOS app registers.
    public static let scheme = "cmux-next"

    /// `cmux-next://pair#<base64url JSON>`. The payload sits in the fragment
    /// so it never reaches a server if the link is opened in a browser.
    public var url: URL {
        let json = (try? JSONEncoder.sorted.encode(self)) ?? Data()
        return URL(string: "\(Self.scheme)://pair#\(json.base64URLEncoded)")!
    }

    /// Parses a pairing link or the raw text of a pairing QR code.
    public init(link: String) throws {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == Self.scheme, url.host == "pair",
              let fragment = url.fragment, let json = Data(base64URLEncoded: fragment) else {
            throw PairingError.notAPairingLink
        }
        let decoded: PairingInvitation
        do { decoded = try JSONDecoder().decode(PairingInvitation.self, from: json) } catch {
            throw PairingError.notAPairingLink
        }
        guard decoded.version == Self.version else { throw PairingError.unsupportedVersion(decoded.version) }
        self = decoded
    }
}

public enum PairingError: Error, Equatable, Sendable, LocalizedError {
    case notAPairingLink
    case unsupportedVersion(Int)
    case expired
    case refused(String)
    case unreachable

    public var errorDescription: String? {
        switch self {
        case .notAPairingLink: "This isn't a cmux pairing code."
        case .unsupportedVersion: "This pairing code is from a newer cmux. Update the app and try again."
        case .expired: "This pairing code expired. Show a new one on your Mac."
        case .refused(let reason): reason
        case .unreachable: "Couldn't reach your Mac. Make sure both devices are on the same network, or on your tailnet."
        }
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
