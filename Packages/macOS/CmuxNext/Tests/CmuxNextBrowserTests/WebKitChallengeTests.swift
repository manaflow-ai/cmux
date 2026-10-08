import AppKit
import Foundation
import CmuxNextDesign
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
        // A long realm wraps instead of being cut at the bar's width.
        bar.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        bar.layoutSubtreeIfNeeded()
        bar.layoutSubtreeIfNeeded()
        #expect(bar.messageLineCount > 1, "the realm wraps to a second line")
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
        view.detailsButton.performClick(nil)
        view.proceedButton.performClick(nil)
        view.backButton.performClick(nil)
        #expect(proceeded && wentBack)
        view.show(BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost, message: "no host"))
        #expect(!view.isCertificateInterstitial)
    }
}

/// cx-d0d.21: the sign-in sheet remembers nothing unless "Remember password"
/// is checked; the certificate interstitial makes Back to Safety the default
/// and keeps Proceed behind Show Details.
@MainActor
@Suite(.serialized)
struct BrowserChallengeUITests {
    static func answer(remember: Bool?) -> CmuxDialogAnswer {
        var values: [String: CmuxDialogValue] = ["user": .text("ada"), "password": .text("s3cret")]
        if let remember { values["remember"] = .bool(remember) }
        return CmuxDialogAnswer(button: "sign-in", role: .default, values: values)
    }

    @Test func theSignInSheetOffersRememberUncheckedAndRemembersNothingByDefault() throws {
        let spec = BrowserHTTPAuth.spec(host: "intranet.test", realm: "Staff", isSecure: true, failedBefore: false, user: nil)
        let remember = spec.fields.first { $0.id == "remember" }
        guard case .check(_, let title, let on)? = remember else {
            Issue.record("no Remember check box")
            return
        }
        #expect(!on, "unchecked by default")
        #expect(!title.isEmpty)
        let once = try #require(BrowserHTTPAuth.credential(for: Self.answer(remember: false)))
        #expect(once.persistence == .forSession)
        let kept = try #require(BrowserHTTPAuth.credential(for: Self.answer(remember: true)))
        #expect(kept.persistence == .permanent)
        #expect(kept.user == "ada")
    }

    @Test func theRememberChoiceReachesTheWebKitCredential() throws {
        let response = BrowserPromptDialogs.response(to: Self.answer(remember: true), for: .credentials(host: "h", realm: nil))
        #expect(response == .credentials(user: "ada", password: "s3cret", remember: true))
        #expect(try #require(BrowserHTTPAuth.urlCredential(for: response)).persistence == .permanent)
        let plain = BrowserPromptDialogs.response(to: Self.answer(remember: nil), for: .credentials(host: "h", realm: nil))
        #expect(try #require(BrowserHTTPAuth.urlCredential(for: plain)).persistence == .forSession)
        #expect(BrowserHTTPAuth.urlCredential(for: .cancel) == nil)
    }

    @Test func theInterstitialMakesBackToSafetyTheDefaultAndHidesProceedBehindDetails() throws {
        let view = LoadErrorView()
        var proceeded = false, wentBack = 0
        view.onProceed = { proceeded = true }
        view.onBack = { wentBack += 1 }
        let error = BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted,
                                     message: "The certificate for this server is invalid.",
                                     failingURL: URL(string: "https://self-signed.test/"))
        view.show(error)
        #expect(view.backButton.title == Strings.certificateBackToSafety)
        #expect(!view.backButton.isHidden)
        #expect(view.proceedButton.isHidden, "Proceed waits behind Show Details")
        #expect(view.detailsLabel.isHidden)
        #expect(!view.detailsButton.isHidden)
        #expect(view.detailsButton.title == Strings.certificateShowDetails)
        // Return on the interstitial goes back to safety; it never proceeds.
        let returnKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: 0, context: nil, characters: "\r",
                                                      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        #expect(view.acceptsFirstResponder)
        view.keyDown(with: returnKey)
        #expect(wentBack == 1 && !proceeded)
        view.detailsButton.performClick(nil)
        #expect(!view.proceedButton.isHidden)
        #expect(!view.detailsLabel.isHidden)
        #expect(view.detailsLabel.stringValue.contains("self-signed.test"))
        #expect(view.detailsButton.title == Strings.certificateHideDetails)
        view.proceedButton.performClick(nil)
        #expect(proceeded)
        // A new warning starts with the details closed again.
        view.show(error)
        #expect(view.proceedButton.isHidden && view.detailsLabel.isHidden)
        // Another load error shows neither.
        view.show(BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost, message: "no host"))
        #expect(view.detailsButton.isHidden && view.proceedButton.isHidden)
    }
}
