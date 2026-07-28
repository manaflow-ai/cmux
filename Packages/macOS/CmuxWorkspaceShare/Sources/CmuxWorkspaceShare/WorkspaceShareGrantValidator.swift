public import Foundation

/// Pure validation for share API grants before URLs or tokens reach transport.
public struct WorkspaceShareGrantValidator: Sendable {
    /// Maximum bearer-token UTF-8 bytes accepted by the relay.
    public static let maximumTokenBytes = 8 * 1_024

    /// Maximum UTF-8 bytes for a URL string returned by the API.
    public static let maximumURLBytes = 4 * 1_024

    /// Worker grammar: 8...64 ASCII alphanumeric characters.
    public static func isValidCode(_ code: String) -> Bool {
        let utf8 = code.utf8
        guard (8...64).contains(utf8.count) else { return false }
        return utf8.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
        }
    }

    /// Validates a nonempty, bounded bearer token without retaining controls.
    public static func isValidToken(_ token: String) -> Bool {
        let byteCount = token.utf8.count
        return byteCount > 0
            && byteCount <= maximumTokenBytes
            && token.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
    }

    /// Parses a bounded relay URL whose scheme is `ws` or `wss`.
    public static func webSocketURL(from value: String) -> URL? {
        validatedURL(
            from: value,
            secureScheme: "wss",
            loopbackScheme: "ws"
        )
    }

    /// Parses a bounded guest URL whose scheme is `http` or `https`.
    public static func sharePageURL(from value: String) -> URL? {
        validatedURL(
            from: value,
            secureScheme: "https",
            loopbackScheme: "http"
        )
    }

    /// Validates finite positive Unix seconds.
    public static func isValidExpiration(_ expiresAt: Double) -> Bool {
        expiresAt.isFinite && expiresAt > 0
    }

    private static func validatedURL(
        from value: String,
        secureScheme: String,
        loopbackScheme: String
    ) -> URL? {
        let byteCount = value.utf8.count
        guard byteCount > 0,
              byteCount <= maximumURLBytes,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              scheme == secureScheme
                  || (scheme == loopbackScheme && isLoopback(host)),
              components.user == nil,
              components.password == nil else {
            return nil
        }
        return components.url
    }

    private static func isLoopback(_ host: String) -> Bool {
        let normalizedHost: Substring
        if host.first == "[", host.last == "]" {
            normalizedHost = host.dropFirst().dropLast()
        } else {
            normalizedHost = host[...]
        }
        if normalizedHost == "localhost" || normalizedHost == "::1" {
            return true
        }
        let parts = normalizedHost.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard parts.count == 4,
              parts.first == "127" else {
            return false
        }
        return parts.allSatisfy { part in
            guard !part.isEmpty,
                  part.allSatisfy(\.isNumber),
                  let value = UInt8(part) else {
                return false
            }
            return String(value) == part
        }
    }

    private init() {}
}
