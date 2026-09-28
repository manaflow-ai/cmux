public import Foundation

/// Session delegate for requests routed through a cmux proxy that already
/// carries its credential.
public final class ManagedProxySessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    public override init() {
        super.init()
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (Self.disposition(for: challenge.protectionSpace), nil)
    }

    /// How a challenge is answered.
    public static func disposition(for protectionSpace: URLProtectionSpace) -> URLSession.AuthChallengeDisposition {
        .performDefaultHandling
    }
}
