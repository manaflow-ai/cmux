import Foundation

/// A normalized user-entered host for explicit manual mobile pairing routes.
///
/// Manual hosts are DNS names or IP literals that a user deliberately chooses
/// outside automatic Tailscale discovery. The value is only a host, never a URL:
/// schemes, paths, query/fragment markers, user-info markers, bare colon host
/// text, whitespace, and control characters are rejected before the host is
/// advertised or dialed.
public struct CmxManualHost: Equatable, Sendable {
    /// The normalized bare host, with IPv6 brackets removed when present.
    public let rawValue: String

    /// Creates a normalized manual host.
    ///
    /// - Parameter rawHost: A DNS name or IP literal. IPv6 literals must be
    ///   bracketed (`[fd00::1]`) so ordinary hostnames cannot hide colons.
    public init?(_ rawHost: String) {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let host: String
        let isBracketedHost: Bool
        if trimmed.hasPrefix("[") || trimmed.hasSuffix("]") {
            guard trimmed.hasPrefix("["),
                  trimmed.hasSuffix("]"),
                  trimmed.count > 2 else {
                return nil
            }
            host = String(trimmed.dropFirst().dropLast())
            isBracketedHost = true
        } else {
            host = trimmed
            isBracketedHost = false
        }
        let forbiddenCharacters = isBracketedHost ? "/?#@" : "/?#@:"

        guard !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              host.rangeOfCharacter(from: .controlCharacters) == nil,
              host.rangeOfCharacter(from: CharacterSet(charactersIn: forbiddenCharacters)) == nil,
              host.range(of: "://") == nil else {
            return nil
        }
        self.rawValue = host
    }
}
