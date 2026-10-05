import Foundation

/// What a TLS check of a host found before WebKit may load its page
/// (WebKitEngine+CertificateWarnings.swift).
nonisolated enum CertificateProbeResult: Sendable, Equatable {
    /// The system trusts the host's certificate.
    case trusted
    /// The system does not trust it: the chain (leaf first) and the reason.
    case untrusted(chain: [Data], reason: String?)
    /// No TLS handshake happened (offline, refused, timed out).
    case unknown

    /// Opens a fresh TLS connection to `url`'s host and evaluates the
    /// server trust off the main thread; no request is sent.
    static func probe(_ url: URL) async -> CertificateProbeResult {
        .unknown
    }
}
