import Foundation
import Testing
@testable import CmuxBrowser

struct BrowserDiscardRestoreStrategyTests {
    private let pageURL = URL(string: "https://example.com/app#inbox")!
    private let state = Data([0x01, 0x02, 0x03])

    private func capture(anchor: URL?, state: Data?) -> BrowserPageStateCapture {
        BrowserPageStateCapture(
            interactionState: state,
            documentURL: anchor,
            anchorURL: anchor,
            coversNavigationHistory: true,
            containsFormSubmission: false
        )
    }

    @Test("A capture anchored at the restore URL restores its session state")
    func restoresInteractionStateAtAnchor() {
        let strategy = BrowserDiscardRestoreStrategy.resolve(
            restoreURL: pageURL,
            capture: capture(anchor: pageURL, state: state)
        )
        #expect(strategy == .restoreInteractionState(state))
    }

    @Test("Without a capture the restore URL is replayed")
    func replaysWithoutCapture() {
        #expect(BrowserDiscardRestoreStrategy.resolve(restoreURL: pageURL, capture: nil) == .replayURL(pageURL))
    }

    @Test("A capture without session state replays the URL")
    func replaysEmptyState() {
        #expect(
            BrowserDiscardRestoreStrategy.resolve(restoreURL: pageURL, capture: capture(anchor: pageURL, state: nil))
                == .replayURL(pageURL)
        )
        #expect(
            BrowserDiscardRestoreStrategy.resolve(restoreURL: pageURL, capture: capture(anchor: pageURL, state: Data()))
                == .replayURL(pageURL)
        )
    }

    @Test("A pane that moved to another URL since the discard replays that URL")
    func replaysWhenAnchorDiffers() {
        let otherURL = URL(string: "https://example.com/other")!
        #expect(
            BrowserDiscardRestoreStrategy.resolve(restoreURL: otherURL, capture: capture(anchor: pageURL, state: state))
                == .replayURL(otherURL)
        )
    }

    /// Assigning session state for a page shown as a form submission result
    /// makes WebKit send the form again, so such a page loads by URL.
    @Test("A capture whose page came from a form submission replays the URL")
    func replaysFormSubmissionDocument() {
        let submitted = BrowserPageStateCapture(
            interactionState: state,
            documentURL: pageURL,
            anchorURL: pageURL,
            coversNavigationHistory: true,
            containsFormSubmission: true,
            documentHasFormSubmission: true
        )
        #expect(BrowserDiscardRestoreStrategy.resolve(restoreURL: pageURL, capture: submitted) == .replayURL(pageURL))

        var earlierSubmission = submitted
        earlierSubmission.documentHasFormSubmission = false
        #expect(
            BrowserDiscardRestoreStrategy.resolve(restoreURL: pageURL, capture: earlierSubmission)
                == .restoreInteractionState(state)
        )
    }

    @Test(
        "Reload, remote proxy, cloud routing, crash recovery and insecure HTTP replay the URL",
        arguments: [
            BrowserDiscardRestoreStrategy.Conditions(isExplicitReload: true),
            BrowserDiscardRestoreStrategy.Conditions(usesRemoteWorkspaceProxy: true),
            BrowserDiscardRestoreStrategy.Conditions(usesCloudAccessRouting: true),
            BrowserDiscardRestoreStrategy.Conditions(hasRecoverableWebContentTermination: true),
            BrowserDiscardRestoreStrategy.Conditions(requiresInsecureHTTPConsent: true)
        ]
    )
    func forcedReplay(conditions: BrowserDiscardRestoreStrategy.Conditions) {
        #expect(
            BrowserDiscardRestoreStrategy.resolve(
                restoreURL: pageURL,
                capture: capture(anchor: pageURL, state: state),
                conditions: conditions
            ) == .replayURL(pageURL)
        )
    }

    @Test("Web and local file documents restore session state; internal documents do not")
    func restorableSchemes() {
        #expect(BrowserDiscardRestoreStrategy.canRestoreSessionState(for: URL(string: "http://example.com/")))
        #expect(BrowserDiscardRestoreStrategy.canRestoreSessionState(for: URL(string: "HTTPS://example.com/")))
        #expect(BrowserDiscardRestoreStrategy.canRestoreSessionState(for: URL(fileURLWithPath: "/tmp/a.html")))
        #expect(!BrowserDiscardRestoreStrategy.canRestoreSessionState(for: URL(string: "cmux-diff-viewer://t/index")))
        #expect(!BrowserDiscardRestoreStrategy.canRestoreSessionState(for: URL(string: "about:blank")))
        #expect(!BrowserDiscardRestoreStrategy.canRestoreSessionState(for: nil))

        let fileURL = URL(fileURLWithPath: "/tmp/a.html")
        #expect(
            BrowserDiscardRestoreStrategy.resolve(restoreURL: fileURL, capture: capture(anchor: fileURL, state: state))
                == .restoreInteractionState(state)
        )
        let internalURL = URL(string: "cmux-diff-viewer://t/index")!
        #expect(
            BrowserDiscardRestoreStrategy.resolve(restoreURL: internalURL, capture: capture(anchor: internalURL, state: state))
                == .replayURL(internalURL)
        )
    }
}
