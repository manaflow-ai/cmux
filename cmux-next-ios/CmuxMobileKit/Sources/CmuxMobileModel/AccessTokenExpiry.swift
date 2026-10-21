import Foundation

/// The expiry of a JWT access token, read from its payload (no signature
/// check: the service verifies the token; this only decides whether a
/// stored token is worth sending at all).
///
/// Stack's SDK refreshes over the network whenever its stored token was
/// issued more than 75 s ago, even though the token stays valid for minutes.
/// At launch that refresh sat in front of the first dial (`dial_start` to
/// `token_ready`, 0.3 to 0.6 s in verify/perf-latency.md). A token that is
/// still valid for `margin` goes out at once; a service that rejects it
/// (401) makes the caller mint a new one, as before.
public struct AccessTokenExpiry: Equatable, Sendable {
    /// When the token stops being accepted (nil: no readable `exp`).
    public let expiresAt: Date?

    public init(token: String) {
        expiresAt = Self.expiry(of: token)
    }

    /// The token is accepted for at least `margin` more seconds.
    public func isUsable(at now: Date = Date(), margin: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) > margin
    }

    private static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let exp = (object["exp"] as? NSNumber)?.doubleValue
        return exp.map { Date(timeIntervalSince1970: $0) }
    }
}
