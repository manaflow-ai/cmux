import CmuxNextAppCore
import Foundation
import Testing

/// Help > Send Feedback opens cmux's bug report form with its Additional context field prefilled. HQ's reconciler
/// (cmuxterm-hq tools/fleet-reconcilers/feedback_fix.py, MARKER) finds reports sent from the app by that exact text,
/// links each to its fix and tells the reporter which nightly has it, so the form and the text must not drift.
@Suite struct SendFeedbackURLTests {
    @Test func sendFeedbackOpensTheBugFormWithTheAppMarker() throws {
        let parts = try #require(URLComponents(url: StaticURL.feedback.url, resolvingAgainstBaseURL: false))
        #expect(parts.scheme == "https")
        #expect(parts.host == "github.com")
        #expect(parts.path == "/manaflow-ai/cmux/issues/new")
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["template"] == "bug_report.yml")
        #expect(query["additional"] == "Sent from cmux NEXT Send Feedback")
    }
}
