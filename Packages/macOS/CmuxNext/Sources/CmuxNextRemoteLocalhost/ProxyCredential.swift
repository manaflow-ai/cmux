public import Foundation
import Security

/// Proxy credentials: one random user name per route, one secret per launch.
public struct ProxyCredential: Sendable, Hashable {
    public var username: String
    public var password: String

    /// `Proxy-Authorization` value Chromium sends for this credential.
    public var basicAuthorization: String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    /// `bytes` random bytes as lowercase hex (SecRandomCopyBytes). If that call
    /// fails, the bytes come from SystemRandomNumberGenerator (arc4random_buf, also
    /// a cryptographically secure source on Darwin), so the secret stays unguessable.
    public static func randomToken(bytes: Int) -> String {
        let count = max(0, bytes)
        var raw = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &raw) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            raw = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return raw.map { String(format: "%02x", $0) }.joined()
    }

    /// Compares without an early exit, so timing does not reveal a prefix.
    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: a.count ^ b.count)
        for index in 0..<max(a.count, b.count) {
            difference |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
        }
        return difference == 0
    }
}
