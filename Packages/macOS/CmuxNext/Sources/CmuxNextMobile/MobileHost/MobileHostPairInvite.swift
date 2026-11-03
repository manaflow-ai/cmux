import CryptoKit
public import Foundation
import Security

/// The single-use pre-approval behind this Mac's pairing code: a phone that scanned it presents
/// the token in its `auth` (cmux-mobile-host `pairing.rs`), and this Mac allows that phone
/// without the "Allow … to connect?" prompt, once.
///
/// It never widens who may connect. hostd serves a phone only when the service stamped its
/// dial with this Mac's own user (`host.rs` admission), the phone proves its identity key,
/// and the app's paired list is the signed-in user's; a token only stands in for the person's
/// Allow. It is 128 random bits, lives ``lifetime``, is bound to this Mac's device id, and is
/// burnt on its first use. Minting a new one revokes the old one.
public struct MobileHostPairTokens: Sendable {
    /// How long a shown code pairs a phone.
    public static let lifetime: TimeInterval = 300

    /// The live token, the Mac device id it was minted for, and when it expires.
    private var live: (token: String, macDeviceID: String, expiresAt: Date)?

    public init() {}

    /// The live token for `macDeviceID`, reused until a minute before it expires, else a new one.
    public mutating func current(macDeviceID: String, now: Date = Date()) -> (token: String, expiresAt: Date) {
        if let live, live.macDeviceID == macDeviceID, live.expiresAt.timeIntervalSince(now) > 60 {
            return (live.token, live.expiresAt)
        }
        return mint(macDeviceID: macDeviceID, now: now)
    }

    /// A new token for `macDeviceID`; the previous one stops working.
    public mutating func mint(macDeviceID: String, now: Date = Date()) -> (token: String, expiresAt: Date) {
        let token = Self.base64URL(Self.randomBytes(16))
        let expiresAt = now.addingTimeInterval(Self.lifetime)
        live = (token, macDeviceID, expiresAt)
        return (token, expiresAt)
    }

    /// True once for the live token, unexpired, minted for `macDeviceID`; the token is then
    /// burnt. False for anything else (nil, unknown, expired, another Mac id, already used).
    public mutating func redeem(_ token: String?, macDeviceID: String?, now: Date = Date()) -> Bool {
        guard let token, let macDeviceID, let live, live.macDeviceID == macDeviceID, now < live.expiresAt,
              Self.constantTimeEqual(token, live.token) else { return false }
        self.live = nil
        return true
    }

    /// No token works any more (the account changed, iPhone connections went off, the Mac was removed).
    public mutating func revoke() {
        live = nil
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        // Every byte is compared, whatever differs first.
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            // SystemRandomNumberGenerator is cryptographically secure on Apple platforms.
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return Data(bytes)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// What this Mac's pairing code carries: `cmux-next://pair?mac=&team=&name=&t=&k=&e=`. cmux on iPhone
/// opens it (camera or its own scanner), signs in if it must, picks the team and this Mac, and
/// presents `t` in its `auth`, but only to a host that proved the identity key whose SHA-256 is
/// `k`, so a host registered under this Mac's id with a stolen token never sees the token, and
/// never after `e` (the token's expiry, Unix seconds), so a photo of an old code sends nothing.
public struct MobileHostPairInvite: Sendable, Equatable {
    /// The URL scheme cmux on iPhone registers.
    public static let scheme = "cmux-next"

    /// This Mac's mobile device id (`/v1/me/macs` `deviceId`, the challenge's `mac`).
    public var macDeviceID: String
    public var teamID: String
    /// What the phone shows while it connects.
    public var macName: String
    public var token: String
    /// SHA-256 of this Mac's 65-byte identity public key, base64url.
    public var macKeyHash: String
    public var expiresAt: Date

    public init(macDeviceID: String, teamID: String, macName: String, token: String, macPublicKey: Data, expiresAt: Date) {
        self.macDeviceID = macDeviceID
        self.teamID = teamID
        self.macName = macName
        self.token = token
        macKeyHash = MobileHostPairTokens.base64URL(Data(SHA256.hash(data: macPublicKey)))
        self.expiresAt = expiresAt
    }

    /// The code's text.
    public var url: String {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "mac", value: macDeviceID), URLQueryItem(name: "team", value: teamID),
            URLQueryItem(name: "name", value: String(macName.prefix(64))), URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "k", value: macKeyHash),
            URLQueryItem(name: "e", value: Self.expiry(expiresAt)),
        ]
        return components.string ?? ""
    }

    /// `e`: whole Unix seconds, 1 to 12 digits as the phone requires. A time it cannot write
    /// (before 1970, not finite, 1e12 or later) is written 0, which the phone reads as expired.
    public static func expiry(_ date: Date) -> String {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0, seconds < 1e12 else { return "0" }
        return String(format: "%.0f", seconds.rounded(.down))
    }
}
