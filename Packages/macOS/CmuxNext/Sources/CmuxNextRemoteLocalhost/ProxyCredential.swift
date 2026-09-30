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

    /// `bytes` random bytes as lowercase hex (SecRandomCopyBytes).
    public static func randomToken(bytes: Int) -> String {
        var raw = [UInt8](repeating: 0, count: bytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes, &raw)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed") // crash-allow: no secure randomness means no safe proxy secret
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
