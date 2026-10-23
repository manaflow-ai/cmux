import CmuxNextHomeEngine
import Foundation

/// The signed-in Stack account's tokens without Stack: a JWT for `subject`,
/// and how often it was asked for.
@MainActor
final class FakeLeaseTokens: CloudLeaseTokens {
    var isSignedIn: Bool
    let subject: String
    private(set) var asked = 0

    init(subject: String, signedIn: Bool = true) {
        self.subject = subject
        isSignedIn = signedIn
    }

    /// Expires an hour from now (whole seconds).
    let expiry = UInt64(Date().timeIntervalSince1970) + 3600

    func accessToken(forceRefresh: Bool) async throws -> String {
        asked += 1
        return Self.jwt(["sub": subject, "exp": expiry])
    }

    static func jwt(_ claims: [String: Any]) -> String {
        func part(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = part(Data(#"{"alg":"none"}"#.utf8))
        let payload = part((try? JSONSerialization.data(withJSONObject: claims)) ?? Data())
        return "\(header).\(payload).sig"
    }
}
