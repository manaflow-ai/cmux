public import Foundation

/// Session delegate for requests routed through a cmux proxy that already
/// carries its credential.
///
/// Without a delegate, a proxy 407 reaches the system, which asks the user
/// for a proxy password. For a cmux proxy that only means a stale credential
/// or another process on the loopback port, so the request fails instead.
/// Other challenges keep the default handling.
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

    /// Cancels proxy challenges; defers everything else to the system.
    public static func disposition(for protectionSpace: URLProtectionSpace) -> URLSession.AuthChallengeDisposition {
        protectionSpace.isProxy() ? .cancelAuthenticationChallenge : .performDefaultHandling
    }
}
