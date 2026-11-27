import Foundation
import WebKit

/// HTTP authentication and untrusted certificates (Chrome, Safari). A 401
/// with Basic, Digest or NTLM asks for a user name and password in the
/// sign-in sheet; the credential lasts for the session, and stays in cmux's
/// Keychain store only when the user checked "Remember password". An untrusted certificate fails the load, which shows
/// the interstitial; after Proceed the host is trusted for this browser
/// profile until the app quits.
extension WebKitTab: BrowserCertificateBypassing {
    typealias ChallengeDecision = WebKitChallengeDecision

    static func decide(method: String, failures: Int, trusted: Bool, excepted: Bool, proposed: Bool = false) -> ChallengeDecision {
        WebKitChallengeDecision(method: method, failures: failures, trusted: trusted, excepted: excepted, proposed: proposed)
    }

    /// Every challenge but server trust (`webView(_:didReceive:completionHandler:)`,
    /// WebKitTab+PageInfo.swift): HTTP authentication asks in the prompt bar.
    func answer(_ challenge: URLAuthenticationChallenge,
                completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        switch Self.decide(method: space.authenticationMethod, failures: challenge.previousFailureCount, trusted: false,
                           excepted: false, proposed: challenge.proposedCredential?.hasPassword == true) {
        case .defaultHandling, .useServerTrust:
            completionHandler(.performDefaultHandling, nil)
        case .cancel:
            completionHandler(.cancelAuthenticationChallenge, nil)
        case .askCredentials:
            WebKitHTTPSignIn(memory: engine?.httpSignInMemory(for: profileID), key: BrowserHTTPCredentialKey(profile: profileID, space: space),
                             failures: challenge.previousFailureCount, space: space) { [weak self] kind, origin, done in
                guard let self else { return done(.cancel) }
                self.enqueuePrompt(kind, origin: origin, completion: done)
            }.run(completionHandler)
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
    public var canTurnOnCertificateWarnings: Bool { engine?.knowsCertificateBypass(self) ?? false }
    public func turnOnCertificateWarnings() async -> Bool { engine?.turnOnCertificateWarnings(self) ?? false }
}

/// What a WebKit tab does with an authentication challenge.
enum WebKitChallengeDecision: Equatable {
    case defaultHandling
    case askCredentials
    case useServerTrust
    case cancel

    /// Pure: HTTP authentication asks (until 5 failures; the tab first tries
    /// a login the user chose to remember); WebKit's proposed credential
    /// (`proposed`) never answers on its own: it may come from system stores
    /// the user did not choose for this tab (and an incognito tab must not
    /// use). An untrusted server certificate
    /// is used only for a host the user proceeded to.
    init(method: String, failures: Int, trusted: Bool, excepted: Bool, proposed: Bool = false) {
        switch method {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM:
            _ = proposed
            self = failures >= 5 ? .cancel : .askCredentials
        case NSURLAuthenticationMethodServerTrust:
            self = !trusted && excepted ? .useServerTrust : .defaultHandling
        default:
            self = .defaultHandling
        }
    }
}
