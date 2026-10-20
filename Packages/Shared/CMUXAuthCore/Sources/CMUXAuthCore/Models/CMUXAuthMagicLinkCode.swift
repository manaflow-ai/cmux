import Foundation

/// The full magic-link verification code: the characters the user typed plus the
/// opaque nonce the send-email call returned.
///
/// Stack Auth verifies the concatenation, so both halves travel together:
///
/// ```swift
/// let fullCode = CMUXAuthMagicLinkCode(code: entered, nonce: nonce).composed
/// ```
public struct CMUXAuthMagicLinkCode: Equatable, Sendable {
    /// The user-entered code.
    public let code: String
    /// The nonce returned when the magic-link email was sent.
    public let nonce: String

    /// Creates a magic-link code from its parts.
    public init(code: String, nonce: String) {
        self.code = code
        self.nonce = nonce
    }

    /// The composed value Stack Auth verifies (`code` + `nonce`).
    ///
    /// Stack stores generated codes lowercase while email templates display the
    /// visible prefix uppercase, so normalize the user-entered prefix before
    /// appending the opaque nonce.
    public var composed: String {
        code.lowercased() + nonce
    }
}
