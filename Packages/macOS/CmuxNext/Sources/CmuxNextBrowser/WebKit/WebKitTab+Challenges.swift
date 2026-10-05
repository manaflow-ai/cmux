import Foundation
import WebKit

/// HTTP authentication and untrusted certificates (Chrome, Safari). A 401
/// with Basic, Digest or NTLM asks for a user name and password in the
/// prompt bar; the credential is used for this request only (WebKit keeps
/// it for the session). An untrusted certificate fails the load, which shows
/// the interstitial; after Proceed the host is trusted for this browser
/// profile until the app quits.
extension WebKitTab: BrowserCertificateBypassing {
    typealias ChallengeDecision = WebKitChallengeDecision

    static func decide(method: String, failures: Int, trusted: Bool, excepted: Bool) -> ChallengeDecision {
        WebKitChallengeDecision(method: method, failures: failures, trusted: trusted, excepted: excepted)
    }

    /// Every challenge but server trust (`webView(_:didReceive:completionHandler:)`,
    /// WebKitTab+PageInfo.swift): HTTP authentication asks in the prompt bar.
    func answer(_ challenge: URLAuthenticationChallenge,
                completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        switch Self.decide(method: space.authenticationMethod, failures: challenge.previousFailureCount, trusted: false,
                           excepted: false) {
        case .defaultHandling, .useServerTrust:
            completionHandler(.performDefaultHandling, nil)
        case .cancel:
            completionHandler(.cancelAuthenticationChallenge, nil)
        case .askCredentials:
            let kind = BrowserPromptKind.credentials(host: space.host, realm: space.realm.flatMap { $0.isEmpty ? nil : $0 })
            enqueuePrompt(kind, origin: space.host) { response in
                guard case .credentials(let user, let password) = response else {
                    return completionHandler(.cancelAuthenticationChallenge, nil)
                }
                completionHandler(.useCredential, URLCredential(user: user, password: password, persistence: .forSession))
            }
        }
    }

    public func proceedPastCertificateError() {
        guard let url = state.loadError?.failingURL, let host = url.host() else { return }
        engine?.allowCertificateException(host: host, profile: profileID)
        load(url)
    }
}

/// Page Info's "Turn on warnings" (WebKitEngine+CertificateWarnings.swift).
extension WebKitTab: BrowserCertificateWarningRevoking {
    public var certificateWarningsTurnedOff: Bool { engine?.certificateWarningsTurnedOff(self) ?? false }
    public var certificateWarningScope: BrowserCertificateWarningScope { .site }
    public func turnOnCertificateWarnings() async -> Bool { engine?.turnOnCertificateWarnings(self) ?? false }
}

/// What a WebKit tab does with an authentication challenge.
enum WebKitChallengeDecision: Equatable {
    case defaultHandling
    case askCredentials
    case useServerTrust
    case cancel

    /// Pure: HTTP authentication asks (until 5 failures); an untrusted
    /// server certificate is used only for a host the user proceeded to.
    init(method: String, failures: Int, trusted: Bool, excepted: Bool) {
        switch method {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM:
            self = failures >= 5 ? .cancel : .askCredentials
        case NSURLAuthenticationMethodServerTrust:
            self = !trusted && excepted ? .useServerTrust : .defaultHandling
        default:
            self = .defaultHandling
        }
    }
}
