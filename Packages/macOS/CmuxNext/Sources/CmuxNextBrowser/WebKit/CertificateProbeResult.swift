import Foundation

/// What a TLS check of a host found before WebKit may load its page
/// (WebKitEngine+CertificateWarnings.swift).
nonisolated enum CertificateProbeResult: Sendable, Equatable {
    /// The system trusts the host's certificate.
    case trusted
    /// The system does not trust it: the chain (leaf first) and the reason.
    case untrusted(chain: [Data], reason: String?)
    /// No TLS handshake happened (offline, refused, timed out).
    case unknown

    /// Opens a fresh TLS connection to `url`'s host and evaluates the
    /// server trust off the main thread; no request is sent.
    static func probe(_ url: URL) async -> CertificateProbeResult {
        let (results, report) = AsyncStream.makeStream(of: CertificateProbeResult.self, bufferingPolicy: .bufferingNewest(1))
        let session = URLSession(configuration: .ephemeral, delegate: CertificateProbeDelegate(report: report), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        // The delegate cancels at the TLS challenge: the request never goes out.
        _ = try? await session.data(for: request)
        report.finish()
        for await result in results { return result }
        return .unknown
    }
}

/// Answers the probe's server-trust challenge: evaluates it (on the
/// session's queue, never the main thread), reports the result, and
/// cancels, so nothing is sent to the server.
nonisolated final class CertificateProbeDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let report: AsyncStream<CertificateProbeResult>.Continuation

    init(report: AsyncStream<CertificateProbeResult>.Continuation) {
        self.report = report
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        answer(challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        answer(challenge)
    }

    private func answer(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.cancelAuthenticationChallenge, nil) }
        if let failure = ServerTrustBox(trust: trust).evaluate() {
            report.yield(.untrusted(chain: failure.chain, reason: failure.reason))
        } else {
            report.yield(.trusted)
        }
        return (.cancelAuthenticationChallenge, nil)
    }
}
