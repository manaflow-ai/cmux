@testable import CmuxNextBrowser
import Foundation
import Testing

/// The error page has no Try Again for a network failure: the page loads again by itself while in sight (Chrome's
/// `NetErrorAutoReloader`). Leo, 2026-11-22: "vacuous decisions like that should be just done". A failure that would
/// send a form again keeps Try Again (BR-R1), and one the network did not cause is not reloaded by itself.
struct LoadErrorAutoReloadTests {
    @Test func networkFailuresReloadByThemselves() {
        for code in [NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                     NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed] {
            #expect(BrowserLoadError(domain: NSURLErrorDomain, code: code, message: "").isTransientNetworkFailure, "\(code)")
        }
    }

    @Test func otherFailuresDoNot() {
        #expect(!BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL, message: "").isTransientNetworkFailure)
        #expect(!BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted, message: "").isTransientNetworkFailure)
        #expect(!BrowserLoadError(domain: "WebKitErrorDomain", code: NSURLErrorTimedOut, message: "").isTransientNetworkFailure)
    }

    @Test func aFailureSendsNoFormUnlessTheEngineSaysSo() {
        var error = BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, message: "")
        #expect(!error.sentForm)
        error.sentForm = true
        #expect(error.sentForm, "a POST's failure keeps Try Again")
    }
}
