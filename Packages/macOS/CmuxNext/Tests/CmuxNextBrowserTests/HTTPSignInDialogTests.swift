import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextBrowser

/// The HTTP sign-in dialog says what Chrome's login dialog says (audit 4, P2): a plain-http server gets the
/// "sent without encryption" line, a second ask after a refused login gets the "not correct" line, and Cancel
/// lets the server's own 401 page load instead of cancelling the navigation.
@MainActor @Suite(.timeLimit(.minutes(1))) struct HTTPSignInDialogTests {
    private let profile = BrowserProfileID(rawValue: UUID())

    private func space(_ scheme: String) -> URLProtectionSpace {
        URLProtectionSpace(host: "intranet.example", port: scheme == NSURLProtectionSpaceHTTPS ? 443 : 80, protocol: scheme,
                           realm: "staff", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
    }

    /// The dialog the tab shows for one challenge, and the challenge's answer after `response`.
    private func ask(_ space: URLProtectionSpace, failures: Int, refusedUser: String? = nil,
                     response: BrowserPromptResponse) async -> (spec: CmuxDialogSpec?, disposition: URLSession.AuthChallengeDisposition) {
        var shown: CmuxDialogSpec?
        let signIn = WebKitHTTPSignIn(memory: nil, key: BrowserHTTPCredentialKey(profile: profile, space: space), failures: failures,
                                      space: space, refusedUser: refusedUser, lanes: nil) { kind, origin, done in
            let prompt = BrowserPrompt(kind: kind, origin: origin) { _ in }
            shown = BrowserPromptDialogs.spec(for: prompt)
            done(response)
        }
        let disposition = await withCheckedContinuation { (done: CheckedContinuation<URLSession.AuthChallengeDisposition, Never>) in
            signIn.run { disposition, _ in done.resume(returning: disposition) }
        }
        return (shown, disposition)
    }

    private func expected(secure: Bool, failed: Bool, user: String? = nil) -> CmuxDialogSpec {
        BrowserHTTPAuth.spec(host: "intranet.example", realm: "staff", isSecure: secure, failedBefore: failed, user: user)
    }

    @Test func aPlainHTTPServerWarnsThatThePasswordIsNotEncrypted() async {
        let (spec, _) = await ask(space(NSURLProtectionSpaceHTTP), failures: 0, response: .cancel)
        #expect(spec == expected(secure: false, failed: false))
    }

    @Test func aSecondAskAfterARefusedLoginSaysTheLoginWasNotCorrect() async {
        let (spec, _) = await ask(space(NSURLProtectionSpaceHTTPS), failures: 1, response: .cancel)
        #expect(spec == expected(secure: true, failed: true))
    }

    @Test func aFirstAskOverHTTPSHasNoWarning() async {
        let (spec, _) = await ask(space(NSURLProtectionSpaceHTTPS), failures: 0, response: .cancel)
        #expect(spec == expected(secure: true, failed: false))
    }

    /// Chrome and Safari show the server's 401 page after Cancel; cancelling the challenge would cancel the
    /// whole navigation and leave the tab on the old page with no word of why.
    @Test func cancelLoadsTheServersOwnPage() async {
        let (_, disposition) = await ask(space(NSURLProtectionSpaceHTTPS), failures: 0, response: .cancel)
        #expect(disposition == .rejectProtectionSpace)
    }

    @Test func aSecondAskFillsInTheRefusedUserName() async {
        let (spec, _) = await ask(space(NSURLProtectionSpaceHTTPS), failures: 1, refusedUser: "ada", response: .cancel)
        #expect(spec == expected(secure: true, failed: true, user: "ada"))
    }

    /// A first ask never fills in a user name WebKit proposes: it may come from a system store the person did
    /// not choose for this tab (and an incognito tab must not read).
    @Test func aFirstAskFillsInNoUserName() async {
        let (spec, _) = await ask(space(NSURLProtectionSpaceHTTPS), failures: 0, refusedUser: "ada", response: .cancel)
        #expect(spec == expected(secure: true, failed: false))
    }

    /// A proxy's login is never called encrypted: an "HTTPS proxy" space is a proxy for https addresses.
    @Test func noProxyLoginIsCalledEncrypted() {
        let https = URLProtectionSpace(proxyHost: "proxy.example", port: 443, type: NSURLProtectionSpaceHTTPSProxy, realm: nil,
                                       authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let http = URLProtectionSpace(proxyHost: "proxy.example", port: 8080, type: NSURLProtectionSpaceHTTPProxy, realm: nil,
                                      authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        #expect(!BrowserHTTPAuth.isSecure(https))
        #expect(!BrowserHTTPAuth.isSecure(http))
    }
}
