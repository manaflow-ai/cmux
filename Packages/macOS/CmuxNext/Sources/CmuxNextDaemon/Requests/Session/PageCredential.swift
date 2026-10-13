import Foundation

/// `page-credential` (`page-credential-v1`, cmux-tui spec/commands.md): a credential for the
/// app's own page, for the verified app connection only. A page that connects with it is the
/// person's own client and gets the Cloud lease the app set (`ws-cloud-conversations-v1`); the
/// file token next to the socket never does.
public struct PageCredentialRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var credential: String
        /// Seconds the credential lives (8 h).
        public var expiresIn: UInt64
    }

    public static let command = "page-credential"
    public static var requiredCapability: String? { DaemonCapabilities.shared.pageCredential }

    public init() {}
}
