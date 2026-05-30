import Foundation

/// Validates the HTTP `Host` and `Origin` headers against a loopback
/// allow-list (spec §5.3 — DNS-rebinding mitigation).
///
/// A browser that resolves an attacker-controlled hostname to
/// `127.0.0.1` can still talk to a loopback HTTP server, so the
/// listener cannot trust that "we accepted the TCP connection on
/// 127.0.0.1" implies "the request came from a same-origin context".
/// Restricting `Host` to `127.0.0.1:<port>` / `localhost:<port>` and
/// rejecting any non-loopback `Origin` defeats the rebind path.
///
/// `Origin` is treated as a **negative signal only**: a missing
/// `Origin` (e.g. CLI / `curl` callers) is permitted, but a present
/// non-loopback `Origin` is rejected. UDS callers skip this check
/// entirely (file-permission-gated already).
public struct HostAllowlist: Sendable {
    /// Outcome of an evaluation. Distinct cases let the transport
    /// map to 400 (missing host) vs. 403 (rebinding attempt).
    public enum Result: Equatable, Sendable {
        /// Host and Origin both pass; request may proceed.
        case ok
        /// HTTP/1.1 request omitted the mandatory `Host` header.
        case missingHost
        /// `Host` was present but not a loopback name + bound port.
        case forbiddenHost
        /// `Origin` was present and not a loopback URL on the bound
        /// port.
        case forbiddenOrigin
    }

    private let allowedHosts: Set<String>
    private let allowedOrigins: Set<String>

    /// Creates an allow-list pinned to the loopback names on
    /// `port`. Re-create the allow-list if the listener is rebound
    /// to a different port.
    ///
    /// - Parameter port: Bound TCP port of the loopback listener.
    public init(port: Int) {
        self.allowedHosts = [
            "127.0.0.1:\(port)",
            "localhost:\(port)",
        ]
        self.allowedOrigins = [
            "http://127.0.0.1:\(port)",
            "http://localhost:\(port)",
        ]
    }

    /// Evaluates a request's `Host` and `Origin` headers.
    ///
    /// - Parameters:
    ///   - host: `Host` header value. `nil` triggers
    ///     ``Result/missingHost``.
    ///   - origin: `Origin` header value, or `nil` if the request
    ///     had no `Origin` (CLI / `curl` style callers). Missing
    ///     `Origin` is allowed — the check is a negative signal,
    ///     not a positive one.
    /// - Returns: ``Result/ok`` when the request may proceed,
    ///   otherwise the specific rejection cause.
    public func evaluate(host: String?, origin: String?) -> Result {
        guard let host else { return .missingHost }
        guard allowedHosts.contains(host.lowercased()) else {
            return .forbiddenHost
        }
        if let origin, !allowedOrigins.contains(origin.lowercased()) {
            return .forbiddenOrigin
        }
        return .ok
    }
}
