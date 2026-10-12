import CryptoKit
import Foundation
import Security
import Testing

@testable import CmuxBrowser

@Suite
struct BrowserServerTrustFingerprintTests {
    /// Self-signed P-256 certificate for CN=cmux-trust-fingerprint.test.
    private static let leafCertificateDER = Data(base64Encoded: "MIIBozCCAUmgAwIBAgIUERrra7u7YJ5+iX0Y1UWEmPButLswCgYIKoZIzj0EAwIwJjEkMCIGA1UEAwwbY211eC10cnVzdC1maW5nZXJwcmludC50ZXN0MCAXDTI2MTAxMjA1NDQxMloYDzIxMjYwOTE4MDU0NDEyWjAmMSQwIgYDVQQDDBtjbXV4LXRydXN0LWZpbmdlcnByaW50LnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATTVi7oNmfJkC85uk4DJ7sbSRIctQszUX6rBhEGguT1apZ2N3km5lEczGGzPSv7Jfddf9Ip8zJcq+Iwiffssk8yo1MwUTAdBgNVHQ4EFgQUlEb/V7A6Z9L+pRFIe6Db1s4W/0YwHwYDVR0jBBgwFoAUlEb/V7A6Z9L+pRFIe6Db1s4W/0YwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEAtha1kN/dbGo81KOQsoSE431MYuLZ5uvUpN+ufq7XkJcCIETBcHrAyirWEqSfzE3YBzpwetZXUMEyVYg30uxplotC")!

    private func makeUnevaluatedTrust() throws -> (SecTrust, SecCertificate) {
        let certificate = try #require(
            SecCertificateCreateWithData(nil, Self.leafCertificateDER as CFData)
        )
        let policy = SecPolicyCreateSSL(true, "cmux-trust-fingerprint.test" as CFString)
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess)
        return (try #require(trust), certificate)
    }

    /// #19726: WebKit delivers server-trust challenges on the main thread.
    /// Fingerprinting the leaf must not evaluate the trust, which is a
    /// synchronous round trip to trustd that stalled the main thread for
    /// seconds when it was slow.
    @Test func fingerprintHashesTheLeafWithoutEvaluatingTrust() throws {
        let (trust, certificate) = try makeUnevaluatedTrust()

        let fingerprint = try #require(BrowserServerTrustFingerprint(serverTrust: trust))

        var result = SecTrustResultType.unspecified
        #expect(SecTrustGetTrustResult(trust, &result) == errSecSuccess)
        #expect(result == .invalid, "fingerprinting evaluated the trust (result \(result.rawValue))")
        let leafData = SecCertificateCopyData(certificate) as Data
        #expect(fingerprint.sha256 == Data(SHA256.hash(data: leafData)))
    }
}
