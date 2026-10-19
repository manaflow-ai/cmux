import CryptoKit
import Foundation

/// Checks session routing metadata against the already registered account; the owner verifies the bearer.
struct StackSessionIdentity {
    let project: String
    let account: String
    let user: String

    init(_ bearer: String, context: NativeInstallContext) throws {
        let pieces = bearer.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3, let data = Data(base64URLEncoded: String(pieces[1])),
              let claims = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = claims["sub"] as? String, account == context.account,
              let issuer = claims["iss"] as? String, issuer.hasPrefix("https://api.stack-auth.com/api/v1/projects/") else {
            throw NativeDeviceEnrollmentError.signedOut
        }
        let project = String(issuer.dropFirst("https://api.stack-auth.com/api/v1/projects/".count))
        guard !project.isEmpty, project.utf8.count <= 128,
              project.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }) else {
            throw NativeDeviceEnrollmentError.signedOut
        }
        let user = "user_" + String(SHA256.hash(data: Data("stack:\(project):\(account)".utf8)).map { String(format: "%02x", $0) }.joined().prefix(20))
        guard user == context.user else { throw NativeDeviceEnrollmentError.signedOut }
        self.project = project; self.account = account; self.user = user
    }
}
