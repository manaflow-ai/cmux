import CryptoKit
public import Foundation
public import Security

public struct BrowserServerTrustFingerprint: Hashable {
    public let sha256: Data

    public init(sha256: Data) {
        self.sha256 = sha256
    }

    /// Hashes the leaf certificate. WebKit delivers server-trust challenges on
    /// the main thread, so this reads the leaf without evaluating the trust:
    /// `SecTrustCopyCertificateChain` evaluates an unevaluated trust with a
    /// synchronous trustd round trip, which stalled the main thread for
    /// seconds (#19726). The deprecated index accessor returns the leaf as-is.
    public init?(serverTrust trust: SecTrust) {
        guard let certificate = SecTrustGetCertificateAtIndex(trust, 0) else { return nil }
        let certificateData = SecCertificateCopyData(certificate) as Data
        sha256 = Data(SHA256.hash(data: certificateData))
    }
}
