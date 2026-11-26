import CmuxBrowser
import Foundation
import Testing

// Regression coverage for https://github.com/manaflow-ai/cmux/issues/53548:
// WebKit keeps one Extensible SSO authorization per website data store, and a
// second navigation allowed while the first is still with the extension
// replaces it. Two tabs opened together on a sign-in page were both left blank.
@MainActor
@Suite
struct BrowserSingleSignOnNavigationGateTests {
    private final class WebView {}

    @MainActor
    private final class Journal {
        var decisions: [String] = []
        var checkedURLs: [URL] = []

        func admission(_ name: String, stillInFlight: Bool = true) -> BrowserSingleSignOnNavigationGate.Admission {
            { admitted in
                self.decisions.append("\(name):\(admitted ? "allow" : "cancel")")
                return stillInFlight
            }
        }
    }

    private let signInURL = URL(string: "https://login.example.com/authorize?state=1")!
    private let plainURL = URL(string: "https://example.com/")!

    private func makeGate() -> BrowserSingleSignOnNavigationGate {
        BrowserSingleSignOnNavigationGate { $0.host == "login.example.com" }
    }

    @Test func secondWebViewWaitsUntilTheFirstNavigationHasAnOutcome() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        let second = WebView()

        gate.admit(url: signInURL, owner: first, admission: journal.admission("first"))
        gate.admit(url: signInURL, owner: second, admission: journal.admission("second"))
        #expect(journal.decisions == ["first:allow"])

        gate.resolve(first)
        #expect(journal.decisions == ["first:allow", "second:allow"])
    }

    @Test func waitingWebViewsAreAdmittedOneAtATimeInArrivalOrder() {
        let gate = makeGate()
        let journal = Journal()
        let webViews = [WebView(), WebView(), WebView()]

        for (index, webView) in webViews.enumerated() {
            gate.admit(url: signInURL, owner: webView, admission: journal.admission("\(index)"))
        }
        #expect(journal.decisions == ["0:allow"])

        gate.resolve(webViews[0])
        #expect(journal.decisions == ["0:allow", "1:allow"])

        gate.resolve(webViews[1])
        #expect(journal.decisions == ["0:allow", "1:allow", "2:allow"])
    }

    @Test func outcomeFromAWaitingWebViewDoesNotAdmitIt() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        let second = WebView()

        gate.admit(url: signInURL, owner: first, admission: journal.admission("first"))
        gate.admit(url: signInURL, owner: second, admission: journal.admission("second"))
        gate.resolve(second)

        #expect(journal.decisions == ["first:allow"])
    }

    @Test func urlNoExtensionTakesIsAdmittedWhileAnotherWebViewHoldsTheGate() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        let second = WebView()

        gate.admit(url: signInURL, owner: first, admission: journal.admission("first"))
        gate.admit(url: plainURL, owner: second, admission: journal.admission("plain"))
        gate.admit(url: nil, owner: second, admission: journal.admission("none"))

        #expect(journal.decisions == ["first:allow", "plain:allow", "none:allow"])
    }

    @Test func onlyWebURLsAreOfferedToTheExtensionCheck() {
        let journal = Journal()
        let gate = BrowserSingleSignOnNavigationGate { url in
            journal.checkedURLs.append(url)
            return true
        }
        let first = WebView()
        let second = WebView()
        let fileURL = URL(fileURLWithPath: "/tmp/login.example.com.html")

        gate.admit(url: signInURL, owner: first, admission: journal.admission("first"))
        gate.admit(url: fileURL, owner: second, admission: journal.admission("file"))

        #expect(journal.decisions == ["first:allow", "file:allow"])
        #expect(journal.checkedURLs == [signInURL])
    }

    @Test func webViewHoldingTheGateIsAdmittedAgainAheadOfWaiters() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        let second = WebView()

        gate.admit(url: signInURL, owner: first, admission: journal.admission("first"))
        gate.admit(url: signInURL, owner: second, admission: journal.admission("second"))
        gate.admit(url: signInURL, owner: first, admission: journal.admission("first-result"))
        #expect(journal.decisions == ["first:allow", "first-result:allow"])

        gate.resolve(first)
        #expect(journal.decisions == ["first:allow", "first-result:allow", "second:allow"])
    }

    @Test func navigationThatIsAlreadyOverDoesNotHoldTheGate() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        let second = WebView()
        let third = WebView()

        gate.admit(url: signInURL, owner: first, admission: journal.admission("first", stillInFlight: false))
        gate.admit(url: signInURL, owner: second, admission: journal.admission("second"))
        gate.admit(url: signInURL, owner: third, admission: journal.admission("third"))

        #expect(journal.decisions == ["first:allow", "second:allow"])
    }

    @Test func abandonedWaiterIsCancelledAndNeverAdmitted() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        let second = WebView()
        let third = WebView()

        gate.admit(url: signInURL, owner: first, admission: journal.admission("first"))
        gate.admit(url: signInURL, owner: second, admission: journal.admission("second"))
        gate.admit(url: signInURL, owner: third, admission: journal.admission("third"))
        gate.abandon(second)
        #expect(journal.decisions == ["first:allow", "second:cancel"])

        gate.resolve(first)
        #expect(journal.decisions == ["first:allow", "second:cancel", "third:allow"])
    }

    @Test func abandoningTheWebViewHoldingTheGateAdmitsTheNextWaiter() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        let second = WebView()

        gate.admit(url: signInURL, owner: first, admission: journal.admission("first"))
        gate.admit(url: signInURL, owner: second, admission: journal.admission("second"))
        gate.abandon(first)

        #expect(journal.decisions == ["first:allow", "second:allow"])
    }

    @Test func webViewThatWentAwayWithoutAnOutcomeStopsHoldingTheGate() {
        let gate = makeGate()
        let journal = Journal()
        var first: WebView? = WebView()
        let second = WebView()
        let third = WebView()

        gate.admit(url: signInURL, owner: first!, admission: journal.admission("first"))
        gate.admit(url: signInURL, owner: second, admission: journal.admission("second"))
        first = nil
        gate.admit(url: signInURL, owner: third, admission: journal.admission("third"))
        #expect(journal.decisions == ["first:allow", "second:allow"])

        gate.resolve(second)
        #expect(journal.decisions == ["first:allow", "second:allow", "third:allow"])
    }

    @Test func waiterWhoseWebViewWentAwayIsCancelledWhenItsTurnComes() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        var second: WebView? = WebView()
        let third = WebView()

        gate.admit(url: signInURL, owner: first, admission: journal.admission("first"))
        gate.admit(url: signInURL, owner: second!, admission: journal.admission("second"))
        gate.admit(url: signInURL, owner: third, admission: journal.admission("third"))
        second = nil
        gate.resolve(first)

        #expect(journal.decisions == ["first:allow", "second:cancel", "third:allow"])
    }

    @Test func newerSignInOfAWaitingWebViewCancelsItsOlderOneAndWaitsAgain() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        let second = WebView()
        let third = WebView()

        gate.admit(url: signInURL, owner: first, admission: journal.admission("first"))
        gate.admit(url: signInURL, owner: second, admission: journal.admission("second"))
        gate.admit(url: signInURL, owner: third, admission: journal.admission("third"))
        gate.admit(url: signInURL, owner: second, admission: journal.admission("second-reload"))
        #expect(journal.decisions == ["first:allow", "second:cancel"])

        gate.resolve(first)
        #expect(journal.decisions == ["first:allow", "second:cancel", "third:allow"])

        gate.resolve(third)
        #expect(journal.decisions == ["first:allow", "second:cancel", "third:allow", "second-reload:allow"])
    }

    @Test func otherNavigationOfAWaitingWebViewCancelsItsSignIn() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        let second = WebView()

        gate.admit(url: signInURL, owner: first, admission: journal.admission("first"))
        gate.admit(url: signInURL, owner: second, admission: journal.admission("second"))
        gate.admit(url: plainURL, owner: second, admission: journal.admission("second-elsewhere"))
        #expect(journal.decisions == ["first:allow", "second:cancel", "second-elsewhere:allow"])

        gate.resolve(first)
        #expect(journal.decisions == ["first:allow", "second:cancel", "second-elsewhere:allow"])
    }

    @Test func waitingNavigationThatDeclinesItsTurnLetsTheNextOneIn() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        let second = WebView()
        let third = WebView()

        gate.admit(url: signInURL, owner: first, admission: journal.admission("first"))
        gate.admit(url: signInURL, owner: second, admission: journal.admission("second", stillInFlight: false))
        gate.admit(url: signInURL, owner: third, admission: journal.admission("third"))
        gate.resolve(first)

        #expect(journal.decisions == ["first:allow", "second:allow", "third:allow"])
    }

    @Test func followUpOfTheHolderThatReportsNoOutcomeFreesTheGate() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        let second = WebView()

        gate.admit(url: signInURL, owner: first, admission: journal.admission("first"))
        gate.admit(url: signInURL, owner: second, admission: journal.admission("second"))
        gate.admit(url: signInURL, owner: first, admission: journal.admission("first-result", stillInFlight: false))

        #expect(journal.decisions == ["first:allow", "first-result:allow", "second:allow"])
    }

    @Test func outcomeReportedDuringAdmissionDoesNotFreeTheNextHolder() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        let second = WebView()
        let third = WebView()
        let fourth = WebView()

        gate.admit(url: signInURL, owner: first, admission: journal.admission("first"))
        gate.admit(url: signInURL, owner: second) { admitted in
            journal.decisions.append("second:\(admitted ? "allow" : "cancel")")
            gate.resolve(second)
            return false
        }
        gate.admit(url: signInURL, owner: third, admission: journal.admission("third"))
        gate.admit(url: signInURL, owner: fourth, admission: journal.admission("fourth"))
        gate.resolve(first)
        #expect(journal.decisions == ["first:allow", "second:allow", "third:allow"])

        gate.resolve(third)
        #expect(journal.decisions == ["first:allow", "second:allow", "third:allow", "fourth:allow"])
    }

    @Test func holdTakenAgainDuringAdmissionOutlivesTheOneThatReportsNoOutcome() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        let second = WebView()

        gate.admit(url: signInURL, owner: first) { admitted in
            journal.decisions.append("first:\(admitted ? "allow" : "cancel")")
            gate.resolve(first)
            gate.admit(url: signInURL, owner: first, admission: journal.admission("first-again"))
            return false
        }
        gate.admit(url: signInURL, owner: second, admission: journal.admission("second"))
        #expect(journal.decisions == ["first:allow", "first-again:allow"])

        gate.resolve(first)
        #expect(journal.decisions == ["first:allow", "first-again:allow", "second:allow"])
    }
}
