import AppKit
import Foundation
import Testing
@testable import CmuxNextBrowser

/// HTTP authentication and certificate errors in WebKit tabs (Chrome,
/// Safari): a 401 with Basic or Digest asks for a user name and password;
/// an untrusted certificate shows an interstitial that can go back or,
/// after an explicit choice, proceed for that host until the app quits.
@MainActor
@Suite(.serialized)
struct WebKitChallengeTests {
    typealias D = WebKitTab.ChallengeDecision

    @Test func challengesMapToDecisions() {
        let basic = NSURLAuthenticationMethodHTTPBasic, digest = NSURLAuthenticationMethodHTTPDigest
        let trust = NSURLAuthenticationMethodServerTrust
        #expect(WebKitTab.decide(method: basic, failures: 0, trusted: false, excepted: false) == D.askCredentials)
        #expect(WebKitTab.decide(method: digest, failures: 2, trusted: false, excepted: false) == D.askCredentials)
        #expect(WebKitTab.decide(method: basic, failures: 5, trusted: false, excepted: false) == D.cancel, "stop asking after 5 failures")
        #expect(WebKitTab.decide(method: trust, failures: 0, trusted: true, excepted: false) == D.defaultHandling)
        #expect(WebKitTab.decide(method: trust, failures: 0, trusted: false, excepted: false) == D.defaultHandling,
                "WebKit fails the load with the certificate error, which shows the interstitial")
        #expect(WebKitTab.decide(method: trust, failures: 0, trusted: false, excepted: true) == D.useServerTrust)
        #expect(WebKitTab.decide(method: NSURLAuthenticationMethodClientCertificate, failures: 0, trusted: false, excepted: false)
            == D.defaultHandling)
    }

    @Test func certificateErrorsAreRecognized() {
        for code in [NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
                     NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid] {
            #expect(BrowserLoadError(domain: NSURLErrorDomain, code: code, message: "").isCertificateError)
        }
        #expect(!BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost, message: "").isCertificateError)
    }

    @Test func theCredentialsPromptReturnsNameAndPassword() throws {
        let bar = PromptBarView()
        var answer: BrowserPromptResponse?
        let prompt = BrowserPrompt(kind: .credentials(host: "intranet.test", realm: "Staff"), origin: "intranet.test") { answer = $0 }
        bar.show(prompt)
        #expect(!bar.userField.isHidden && !bar.passwordField.isHidden)
        bar.userField.stringValue = "ada"
        bar.passwordField.stringValue = "s3cret"
        bar.submit()
        #expect(answer == .credentials(user: "ada", password: "s3cret"))
        #expect(BrowserPrompt(kind: .credentials(host: "h", realm: nil), origin: "h", completion: { _ in }).dismissalResponse == .cancel)
    }

    @Test func theInterstitialOffersBackAndProceed() {
        let view = LoadErrorView()
        var proceeded = false, wentBack = false
        view.onProceed = { proceeded = true }
        view.onBack = { wentBack = true }
        view.show(BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted, message: "untrusted",
                                   failingURL: URL(string: "https://self-signed.test/")))
        #expect(view.isCertificateInterstitial)
        view.proceedButton.performClick(nil)
        view.backButton.performClick(nil)
        #expect(proceeded && wentBack)
        view.show(BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost, message: "no host"))
        #expect(!view.isCertificateInterstitial)
    }
}
