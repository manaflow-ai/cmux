import CryptoKit
public import Foundation
public import Security

public struct BrowserServerTrustFingerprint: Hashable {
    public let sha256: Data

    public init(sha256: Data) {
        self.sha256 = sha256
    }

    public init?(serverTrust trust: SecTrust) {
        let certificate: SecCertificate?
        if #available(macOS 12.0, *) {
            certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        } else {
            certificate = SecTrustGetCertificateAtIndex(trust, 0)
        }

        guard let certificate else { return nil }
        let certificateData = SecCertificateCopyData(certificate) as Data
        sha256 = Data(SHA256.hash(data: certificateData))
    }
}
