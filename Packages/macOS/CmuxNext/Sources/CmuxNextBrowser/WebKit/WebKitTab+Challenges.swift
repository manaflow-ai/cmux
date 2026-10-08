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
        let proposed = challenge.proposedCredential.flatMap { $0.hasPassword ? $0 : nil }
        switch Self.decide(method: space.authenticationMethod, failures: challenge.previousFailureCount, trusted: false,
                           excepted: false, proposed: proposed != nil) {
        case .defaultHandling, .useServerTrust:
            completionHandler(.performDefaultHandling, nil)
        case .useProposedCredential:
            completionHandler(.useCredential, proposed)
        case .cancel:
            completionHandler(.cancelAuthenticationChallenge, nil)
        case .askCredentials:
            let memory = engine?.httpSignInMemory(for: profileID)
            let key = BrowserHTTPCredentialKey(profile: profileID, space: space)
            let failures = challenge.previousFailureCount
            // task-owner: one Keychain read off the main actor, then the answer; ends with it
            Task { [weak self] in
                let remembered = await Task.detached { memory?.remembered(key, failures: failures) }.value
                if let remembered {
                    return completionHandler(.useCredential,
                                             URLCredential(user: remembered.user, password: remembered.password, persistence: .forSession))
                }
                guard let self else { return completionHandler(.cancelAuthenticationChallenge, nil) }
                self.askCredentials(space, key: key, memory: memory, completionHandler: completionHandler)
            }
        }
    }

    /// Shows the sign-in sheet; a checked Remember saves the login, an
    /// unchecked one forgets the saved one (off the main actor).
    private func askCredentials(_ space: URLProtectionSpace, key: BrowserHTTPCredentialKey, memory: BrowserHTTPSignInMemory?,
                                completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let kind = BrowserPromptKind.credentials(host: space.host, realm: space.realm.flatMap { $0.isEmpty ? nil : $0 })
        enqueuePrompt(kind, origin: space.host) { response in
            guard let credential = BrowserHTTPAuth.urlCredential(for: response) else {
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            if let memory {
                // task-owner: one Keychain write off the main actor; nothing waits on it
                Task.detached { memory.record(response, for: key) }
            }
            completionHandler(.useCredential, credential)
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
    /// A remembered credential WebKit proposes (the user checked "Remember password").
    case useProposedCredential
    case useServerTrust
    case cancel

    /// Pure: HTTP authentication uses a remembered password on the first
    /// try, else asks (until 5 failures); an untrusted server certificate is
    /// used only for a host the user proceeded to.
    init(method: String, failures: Int, trusted: Bool, excepted: Bool, proposed: Bool = false) {
        switch method {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM:
            self = failures >= 5 ? .cancel : (proposed && failures == 0 ? .useProposedCredential : .askCredentials)
        case NSURLAuthenticationMethodServerTrust:
            self = !trusted && excepted ? .useServerTrust : .defaultHandling
        default:
            self = .defaultHandling
        }
    }
}
