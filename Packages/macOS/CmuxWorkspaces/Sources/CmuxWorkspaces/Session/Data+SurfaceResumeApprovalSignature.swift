import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Surface-resume approval signing, expressed as an operation on the payload
/// `Data` it signs rather than a static utility namespace. This mirrors the
/// legacy `SurfaceResumeApprovalSignature.sign(_:secret:)` byte-for-byte; only
/// the receiver changed from an explicit `payload` argument to `self`.
extension Data {
    /// The HMAC-SHA256 authentication code of this payload under `secret`,
    /// base64-encoded. Returns an empty string when CryptoKit is unavailable.
    func surfaceResumeApprovalSignature(secret: Data) -> String {
#if canImport(CryptoKit)
        let key = SymmetricKey(data: secret)
        let code = HMAC<SHA256>.authenticationCode(for: self, using: key)
        return Data(code).base64EncodedString()
#else
        return ""
#endif
    }
}
