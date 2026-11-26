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

    /// WebKit asks about a navigation and its delegate takes it straight to the gate.
    private func navigate(
        _ gate: BrowserSingleSignOnNavigationGate,
        to url: URL?,
        in owner: AnyObject,
        admission: @escaping BrowserSingleSignOnNavigationGate.Admission
    ) {
        gate.admit(gate.begin(owner: owner), url: url, admission: admission)
    }

    @Test func secondWebViewWaitsUntilTheFirstNavigationHasAnOutcome() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        let second = WebView()

        navigate(gate, to: signInURL, in: first, admission: journal.admission("first"))
        navigate(gate, to: signInURL, in: second, admission: journal.admission("second"))
        #expect(journal.decisions == ["first:allow"])

        gate.resolve(first)
        #expect(journal.decisions == ["first:allow", "second:allow"])
    }

    @Test func waitingWebViewsAreAdmittedOneAtATimeInArrivalOrder() {
        let gate = makeGate()
        let journal = Journal()
        let webViews = [WebView(), WebView(), WebView()]

        for (index, webView) in webViews.enumerated() {
            navigate(gate, to: signInURL, in: webView, admission: journal.admission("\(index)"))
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

        navigate(gate, to: signInURL, in: first, admission: journal.admission("first"))
        navigate(gate, to: signInURL, in: second, admission: journal.admission("second"))
        gate.resolve(second)

        #expect(journal.decisions == ["first:allow"])
    }

    @Test func urlNoExtensionTakesIsAdmittedWhileAnotherWebViewHoldsTheGate() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        let second = WebView()

        navigate(gate, to: signInURL, in: first, admission: journal.admission("first"))
        navigate(gate, to: plainURL, in: second, admission: journal.admission("plain"))
        navigate(gate, to: nil, in: second, admission: journal.admission("none"))

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

        navigate(gate, to: signInURL, in: first, admission: journal.admission("first"))
        navigate(gate, to: fileURL, in: second, admission: journal.admission("file"))

        #expect(journal.decisions == ["first:allow", "file:allow"])
        #expect(journal.checkedURLs == [signInURL])
    }

    @Test func webViewHoldingTheGateIsAdmittedAgainAheadOfWaiters() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        let second = WebView()

        navigate(gate, to: signInURL, in: first, admission: journal.admission("first"))
        navigate(gate, to: signInURL, in: second, admission: journal.admission("second"))
        navigate(gate, to: signInURL, in: first, admission: journal.admission("first-result"))
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

        navigate(gate, to: signInURL, in: first, admission: journal.admission("first", stillInFlight: false))
        navigate(gate, to: signInURL, in: second, admission: journal.admission("second"))
        navigate(gate, to: signInURL, in: third, admission: journal.admission("third"))

        #expect(journal.decisions == ["first:allow", "second:allow"])
    }

    @Test func abandonedWaiterIsCancelledAndNeverAdmitted() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        let second = WebView()
        let third = WebView()

        navigate(gate, to: signInURL, in: first, admission: journal.admission("first"))
        navigate(gate, to: signInURL, in: second, admission: journal.admission("second"))
        navigate(gate, to: signInURL, in: third, admission: journal.admission("third"))
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

        navigate(gate, to: signInURL, in: first, admission: journal.admission("first"))
        navigate(gate, to: signInURL, in: second, admission: journal.admission("second"))
        gate.abandon(first)

        #expect(journal.decisions == ["first:allow", "second:allow"])
    }

    @Test func webViewThatWentAwayWithoutAnOutcomeStopsHoldingTheGate() {
        let gate = makeGate()
        let journal = Journal()
        var first: WebView? = WebView()
        let second = WebView()
        let third = WebView()

        navigate(gate, to: signInURL, in: first!, admission: journal.admission("first"))
        navigate(gate, to: signInURL, in: second, admission: journal.admission("second"))
        first = nil
        navigate(gate, to: signInURL, in: third, admission: journal.admission("third"))
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

        navigate(gate, to: signInURL, in: first, admission: journal.admission("first"))
        navigate(gate, to: signInURL, in: second!, admission: journal.admission("second"))
        navigate(gate, to: signInURL, in: third, admission: journal.admission("third"))
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

        navigate(gate, to: signInURL, in: first, admission: journal.admission("first"))
        navigate(gate, to: signInURL, in: second, admission: journal.admission("second"))
        navigate(gate, to: signInURL, in: third, admission: journal.admission("third"))
        navigate(gate, to: signInURL, in: second, admission: journal.admission("second-reload"))
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

        navigate(gate, to: signInURL, in: first, admission: journal.admission("first"))
        navigate(gate, to: signInURL, in: second, admission: journal.admission("second"))
        navigate(gate, to: plainURL, in: second, admission: journal.admission("second-elsewhere"))
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

        navigate(gate, to: signInURL, in: first, admission: journal.admission("first"))
        navigate(gate, to: signInURL, in: second, admission: journal.admission("second", stillInFlight: false))
        navigate(gate, to: signInURL, in: third, admission: journal.admission("third"))
        gate.resolve(first)

        #expect(journal.decisions == ["first:allow", "second:allow", "third:allow"])
    }

    @Test func followUpOfTheHolderThatReportsNoOutcomeFreesTheGate() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        let second = WebView()

        navigate(gate, to: signInURL, in: first, admission: journal.admission("first"))
        navigate(gate, to: signInURL, in: second, admission: journal.admission("second"))
        navigate(gate, to: signInURL, in: first, admission: journal.admission("first-result", stillInFlight: false))

        #expect(journal.decisions == ["first:allow", "first-result:allow", "second:allow"])
    }

    @Test func outcomeReportedDuringAdmissionDoesNotFreeTheNextHolder() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        let second = WebView()
        let third = WebView()
        let fourth = WebView()

        navigate(gate, to: signInURL, in: first, admission: journal.admission("first"))
        navigate(gate, to: signInURL, in: second) { admitted in
            journal.decisions.append("second:\(admitted ? "allow" : "cancel")")
            gate.resolve(second)
            return false
        }
        navigate(gate, to: signInURL, in: third, admission: journal.admission("third"))
        navigate(gate, to: signInURL, in: fourth, admission: journal.admission("fourth"))
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

        navigate(gate, to: signInURL, in: first) { admitted in
            journal.decisions.append("first:\(admitted ? "allow" : "cancel")")
            gate.resolve(first)
            navigate(gate, to: signInURL, in: first, admission: journal.admission("first-again"))
            return false
        }
        navigate(gate, to: signInURL, in: second, admission: journal.admission("second"))
        #expect(journal.decisions == ["first:allow", "first-again:allow"])

        gate.resolve(first)
        #expect(journal.decisions == ["first:allow", "first-again:allow", "second:allow"])
    }

    // A delegate may reach the gate some time after WebKit asked, and some
    // navigations never reach it. WebKit drops a navigation still awaiting its
    // decision when the web view starts another or is stopped, and reports
    // nothing, so the gate has to know from the moment WebKit asks.

    @Test func navigationSupersededBeforeItReachesTheGateIsCancelled() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()

        let older = gate.begin(owner: first)
        let newer = gate.begin(owner: first)
        gate.admit(older, url: plainURL, admission: journal.admission("older"))
        gate.admit(newer, url: signInURL, admission: journal.admission("newer"))

        #expect(journal.decisions == ["older:cancel", "newer:allow"])
    }

    @Test func navigationAbandonedBeforeItReachesTheGateIsCancelledAndHoldsNothing() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        let second = WebView()

        let stopped = gate.begin(owner: first)
        gate.abandon(first)
        gate.admit(stopped, url: signInURL, admission: journal.admission("first"))
        navigate(gate, to: signInURL, in: second, admission: journal.admission("second"))

        #expect(journal.decisions == ["first:cancel", "second:allow"])
    }

    @Test func newerNavigationThatNeverReachesTheGateCancelsTheWaitingOne() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        let second = WebView()
        let third = WebView()

        navigate(gate, to: signInURL, in: first, admission: journal.admission("first"))
        navigate(gate, to: signInURL, in: second, admission: journal.admission("second"))
        navigate(gate, to: signInURL, in: third, admission: journal.admission("third"))
        _ = gate.begin(owner: second)
        #expect(journal.decisions == ["first:allow", "second:cancel"])

        gate.resolve(first)
        #expect(journal.decisions == ["first:allow", "second:cancel", "third:allow"])
    }

    @Test func navigationIsDecidedOnlyOnce() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()

        let navigation = gate.begin(owner: first)
        gate.admit(navigation, url: plainURL, admission: journal.admission("once"))
        gate.admit(navigation, url: plainURL, admission: journal.admission("twice"))

        #expect(journal.decisions == ["once:allow", "twice:cancel"])
    }

    @Test func navigationOfAnotherWebViewLeavesThisOneUndecided() {
        let gate = makeGate()
        let journal = Journal()
        let first = WebView()
        let second = WebView()

        let navigation = gate.begin(owner: first)
        _ = gate.begin(owner: second)
        gate.abandon(second)
        gate.admit(navigation, url: plainURL, admission: journal.admission("first"))

        #expect(journal.decisions == ["first:allow"])
    }
}
