import CoreImage
import CryptoKit
import Foundation

/// A Mac's pairing code, `cmux-next://pair?mac=&team=&name=&t=&k=&e=` (the Mac's
/// `MobileHostPairInvite`): scanned in the app or opened from the Camera.
/// The phone moves to `team`, focuses `mac`, and presents `t` in that Mac's
/// `auth` so the Mac skips its Allow prompt once. It never admits another
/// account: the phone still signs in, and the Mac's host still drops dials
/// from other users. `t` goes out only to a Mac that proved the identity key
/// whose SHA-256 is `k` (``LinkPairing``).
public struct PairInvite: Equatable, Sendable, CustomStringConvertible {
    public static let scheme = "cmux-next"
    /// How long the Mac honours a code (`MobileHostPairTokens.lifetime`), counted here from receipt.
    public static let lifetime: TimeInterval = 300

    /// The Mac's mobile device id (`/v1/me/macs` `deviceId`, the challenge's `mac`).
    public let mac: String
    public let team: String
    /// The Mac's name, for display only.
    public let name: String
    /// The single-use pre-approval. Never logged.
    let token: String
    /// base64url SHA-256 of the Mac's 65-byte identity public key.
    let keyHash: String
    public let receivedAt: Date
    /// When the Mac's token expires (`e`, Unix seconds), capped at ``lifetime`` after receipt: a
    /// photo of an old code sends nothing.
    public let expiresAt: Date

    /// The code in `url`; nil for any other link or a malformed code.
    public init?(url: URL, now: Date = Date()) {
        guard url.scheme?.lowercased() == Self.scheme, url.host()?.lowercased() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let mac = value("mac"), Self.matches(mac, Self.idCharacters, 1...128),
              let team = value("team"), Self.matches(team, Self.teamCharacters, 1...128),
              let token = value("t"), Self.matches(token, Self.base64URLCharacters, 16...64),
              let keyHash = value("k"), Self.matches(keyHash, Self.base64URLCharacters, 43...43),
              Self.base64URLDecoded(keyHash)?.count == 32,
              let expiry = value("e"), Self.matches(expiry, Self.digits, 1...12), let seconds = TimeInterval(expiry)
        else { return nil }
        self.mac = mac
        self.team = team
        name = String((value("name") ?? "").filter { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(64))
        self.token = token
        self.keyHash = keyHash
        receivedAt = now
        expiresAt = min(Date(timeIntervalSince1970: seconds), now.addingTimeInterval(Self.lifetime))
    }

    /// The code in scanned text.
    public init?(text: String, now: Date = Date()) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url, now: now)
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        now >= expiresAt || now < receivedAt
    }

    /// Whether `key` (the X9.63 hex a challenge proves) is the key this code names.
    func names(key: String) -> Bool {
        guard let bytes = Data(hex: key) else { return false }
        return Self.base64URL(Data(SHA256.hash(data: bytes))) == keyHash
    }

    /// Never the token.
    public var description: String { "PairInvite(mac: \(mac), team: \(team))" }

    /// The QR payloads in a still image (a screenshot of the Mac's code; the
    /// Simulator has no camera). The live scanner reads codes with AVFoundation.
    public static func payloads(in image: CGImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: CIImage(cgImage: image)) ?? []
        return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    static let base64URLCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    static let teamCharacters = base64URLCharacters
    static let digits = CharacterSet(charactersIn: "0123456789")
    static let idCharacters = base64URLCharacters.union(CharacterSet(charactersIn: ".:"))

    static func matches(_ value: String, _ allowed: CharacterSet, _ length: ClosedRange<Int>) -> Bool {
        length.contains(value.unicodeScalars.count) && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecoded(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

/// The pairing code this phone holds until a Mac's `auth` uses it: one at a
/// time, used once (presented or not) at the first challenge from its Mac,
/// and dropped after ``PairInvite/lifetime``.
public final class PairInvites: @unchecked Sendable {
    // carve-out: a lock, read from the pairing task off the main actor.
    private let lock = NSLock()
    private var held: PairInvite?
    /// Tokens already used at a challenge, until they expire: opening the same code again holds nothing.
    private var used: [String: Date] = [:]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Holds `invite`, unless its token was already used at a challenge (false then).
    @discardableResult
    public func hold(_ invite: PairInvite) -> Bool {
        lock.withLock {
            let at = now()
            used = used.filter { $0.value > at }
            guard used[invite.token] == nil else { return false }
            held = invite
            return true
        }
    }

    /// The held code (for `mac`, when given), unless it expired (it is dropped then).
    public func pending(mac: String? = nil) -> PairInvite? {
        lock.withLock {
            guard let invite = held else { return nil }
            if invite.isExpired(at: now()) {
                held = nil
                return nil
            }
            guard let mac else { return invite }
            return invite.mac.lowercased() == mac.lowercased() ? invite : nil
        }
    }

    /// Drops the held code (for `mac`, when given).
    public func drop(mac: String? = nil) {
        lock.withLock {
            if mac == nil || held?.mac.lowercased() == mac?.lowercased() { held = nil }
        }
    }

    /// The token for the challenge of `mac`, whose proven identity key is
    /// `provenKey` (nil: the Mac proved none). A code for `mac` is used up
    /// here; its token comes back only when it is live and `provenKey` is the
    /// key the code names. Nil for any other Mac (the code stays held).
    func token(mac: String, provenKey: String?) -> String? {
        lock.withLock {
            guard let invite = held, invite.mac.lowercased() == mac.lowercased() else { return nil }
            held = nil
            used[invite.token] = invite.expiresAt
            guard !invite.isExpired(at: now()), let provenKey, invite.names(key: provenKey) else { return nil }
            return invite.token
        }
    }
}
