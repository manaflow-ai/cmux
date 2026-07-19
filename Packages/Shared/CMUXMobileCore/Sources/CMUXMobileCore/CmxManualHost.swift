import Foundation

/// A normalized user-entered host for explicit manual mobile pairing routes.
///
/// Manual hosts are DNS names or IP literals that a user deliberately chooses
/// outside automatic Tailscale discovery. The value is only a host, never a URL:
/// schemes, paths, query/fragment markers, user-info markers, bare colon host
/// text, non-QR-safe characters, whitespace, and control characters are rejected
/// before the host is advertised or dialed.
public struct CmxManualHost: Equatable, Sendable {
    /// The normalized bare host, with IPv6 brackets removed when present.
    public let rawValue: String

    /// Whether this host may be published as a remote manual pairing route.
    ///
    /// Loopback names the publishing machine itself, so advertising it to a
    /// phone would make the phone dial its own local process instead of the Mac.
    public var isAdvertisable: Bool {
        !CmxLoopbackHost().matches(rawValue)
    }

    /// Creates a normalized manual host.
    ///
    /// - Parameter rawHost: A DNS name or IP literal. IPv6 literals must be
    ///   bracketed (`[fd00::1]`) so ordinary hostnames cannot hide colons.
    public init?(_ rawHost: String) {
        guard let host = CmxManualHostParser(
            rawHost: rawHost,
            acceptsBareIPv6: false
        ).normalizedHost else { return nil }
        self.rawValue = host
    }

    /// Creates a manual host from attach-route endpoint form.
    ///
    /// User-entered IPv6 must be bracketed so a typo like `my:host` is rejected
    /// up front. Attach routes store IPv6 without brackets, so route/reconnect
    /// paths use this initializer when they are validating an already-normalized
    /// endpoint host.
    /// - Parameter rawHost: A DNS name, IP literal, or already-normalized bare IPv6 endpoint host.
    public init?(routeHost rawHost: String) {
        guard let host = CmxManualHostParser(
            rawHost: rawHost,
            acceptsBareIPv6: true
        ).normalizedHost else { return nil }
        self.rawValue = host
    }
}
