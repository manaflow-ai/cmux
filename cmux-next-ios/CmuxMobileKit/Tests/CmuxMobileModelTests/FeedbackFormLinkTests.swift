import Foundation
import Testing
@testable import CmuxMobileModel

/// The iPhone's Send feedback opens the bug report form with HQ's report marker in Additional context, so an iPhone
/// report counts like a Mac one (feedback_fix.py matches the marker as a substring of the issue body).
@Suite struct FeedbackFormLinkTests {
    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    @Test func opensTheBugFormWithTheMarker() {
        let url = FeedbackFormLink.url(appVersion: "1.4", build: "812", osVersion: "26.1")
        #expect(url.host == "github.com")
        #expect(url.path == "/manaflow-ai/cmux/issues/new")
        let q = query(url)
        #expect(q["template"] == "bug_report.yml")
        #expect(q["additional"]?.hasPrefix(FeedbackFormLink.marker) == true)
        #expect(q["additional"]?.contains("iPhone, iOS 26.1") == true)
        #expect(q["cmux-version"] == "1.4 (812) iPhone app")
    }

    @Test func markerIsTheOneTheMacSends() {
        // Packages/macOS/CmuxNext StaticURL.feedback: additional=Sent%20from%20cmux%20NEXT%20Send%20Feedback
        #expect(FeedbackFormLink.marker == "Sent from cmux NEXT Send Feedback")
    }

    @Test func aPlusInAVersionSurvives() {
        let url = FeedbackFormLink.url(appVersion: "1.4+dev", build: "1", osVersion: "26.1")
        #expect(url.absoluteString.contains("1.4%2Bdev"))
        #expect(query(url)["cmux-version"] == "1.4+dev (1) iPhone app")
    }
}
