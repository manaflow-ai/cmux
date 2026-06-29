public import Foundation

/// A Keychain client-certificate identity that can satisfy a WebKit mTLS challenge.
///
/// The candidate carries the credential WebKit needs plus sanitized-by-caller
/// display metadata for the certificate picker.
// URLCredential is created once for an auth challenge and then transferred
// to the main-actor WebKit completion callback without mutation.
public struct BrowserClientCertificateCredentialCandidate: @unchecked Sendable {
    /// The certificate subject summary, if Keychain exposes one.
    public let title: String?

    /// The raw certificate serial number rendered as uppercase hexadecimal.
    public let serialNumber: String?

    /// The credential to pass back to WebKit when this candidate is selected.
    public let credential: URLCredential

    /// Creates a client-certificate credential candidate.
    /// - Parameters:
    ///   - title: The certificate subject summary, if available.
    ///   - serialNumber: The raw certificate serial number as displayable text.
    ///   - credential: The WebKit credential backed by a Keychain identity.
    public init(
        title: String? = nil,
        serialNumber: String? = nil,
        credential: URLCredential
    ) {
        self.title = title
        self.serialNumber = serialNumber
        self.credential = credential
    }
}
