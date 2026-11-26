/// Username and password the loopback remote-workspace browser proxy requires.
///
/// The proxy listens on `127.0.0.1`, which every local account can reach, so
/// each tunnel start mints a fresh random credential and hands it only to the
/// embedded browser. The value stays in process memory: descriptions are
/// redacted, and it is never written to logs, argv or socket payloads.
public struct BrowserProxyCredential: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// SOCKS5 username (RFC 1929) and HTTP Basic user.
    public let username: String
    /// SOCKS5 password (RFC 1929) and HTTP Basic password.
    public let password: String

    /// Creates a credential from explicit values.
    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    /// Mints a credential whose password carries 256 random bits.
    public static func random() -> BrowserProxyCredential {
        var generator = SystemRandomNumberGenerator()
        let hexDigits = Array("0123456789abcdef".utf8)
        var passwordBytes: [UInt8] = []
        passwordBytes.reserveCapacity(64)
        for _ in 0..<32 {
            let byte = UInt8.random(in: .min ... .max, using: &generator)
            passwordBytes.append(hexDigits[Int(byte >> 4)])
            passwordBytes.append(hexDigits[Int(byte & 0x0F)])
        }
        return BrowserProxyCredential(
            username: "cmux",
            password: String(decoding: passwordBytes, as: UTF8.self)
        )
    }

    /// Returns whether the offered username and password match, comparing
    /// the bytes in constant time for equal lengths.
    public func matches(username offeredUsername: [UInt8], password offeredPassword: [UInt8]) -> Bool {
        let usernameMatches = Self.constantTimeEqual(Array(username.utf8), offeredUsername)
        let passwordMatches = Self.constantTimeEqual(Array(password.utf8), offeredPassword)
        return usernameMatches && passwordMatches
    }

    /// Redacted so interpolating the credential never exposes the password.
    public var description: String { "BrowserProxyCredential(redacted)" }

    /// Redacted like ``description``.
    public var debugDescription: String { description }

    private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}
