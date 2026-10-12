import Foundation
import Security
import Testing

@Suite
struct TrustProbeTests {
    private static let der = Data(base64Encoded: "MIIBozCCAUmgAwIBAgIUERrra7u7YJ5+iX0Y1UWEmPButLswCgYIKoZIzj0EAwIwJjEkMCIGA1UEAwwbY211eC10cnVzdC1maW5nZXJwcmludC50ZXN0MCAXDTI2MTAxMjA1NDQxMloYDzIxMjYwOTE4MDU0NDEyWjAmMSQwIgYDVQQDDBtjbXV4LXRydXN0LWZpbmdlcnByaW50LnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATTVi7oNmfJkC85uk4DJ7sbSRIctQszUX6rBhEGguT1apZ2N3km5lEczGGzPSv7Jfddf9Ip8zJcq+Iwiffssk8yo1MwUTAdBgNVHQ4EFgQUlEb/V7A6Z9L+pRFIe6Db1s4W/0YwHwYDVR0jBBgwFoAUlEb/V7A6Z9L+pRFIe6Db1s4W/0YwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEAtha1kN/dbGo81KOQsoSE431MYuLZ5uvUpN+ufq7XkJcCIETBcHrAyirWEqSfzE3YBzpwetZXUMEyVYg30uxplotC")!

    private func trust() -> SecTrust {
        let cert = SecCertificateCreateWithData(nil, Self.der as CFData)!
        var t: SecTrust?
        _ = SecTrustCreateWithCertificates(cert, SecPolicyCreateSSL(true, "cmux-trust-fingerprint.test" as CFString), &t)
        return t!
    }

    private func result(_ t: SecTrust) -> UInt32 {
        var r = SecTrustResultType.unspecified
        _ = SecTrustGetTrustResult(t, &r)
        return r.rawValue
    }

    @Test func probe() {
        let fresh = trust()
        let a = result(fresh)
        let a2 = result(fresh)
        let b = trust()
        _ = SecTrustGetCertificateAtIndex(b, 0)
        let bResult = result(b)
        let c = trust()
        _ = SecTrustCopyCertificateChain(c)
        let cResult = result(c)
        let d = trust()
        let count = SecTrustGetCertificateCount(d)
        let dResult = result(d)
        Issue.record("PROBE fresh=\(a) fresh2=\(a2) atIndex0=\(bResult) copyChain=\(cResult) count(\(count))=\(dResult) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    }
}
