import Foundation
import Testing
@testable import CmuxMobileModel

/// The iPhone's Send feedback opens the same bug form as the Mac's, and HQ's feedback_fix.py counts it by the
/// Mac's marker text (MARKER = "Sent from cmux NEXT Send Feedback", a case-insensitive substring of the body).
@Suite struct SendFeedbackURLTests {
    private func query(_ url: URL) throws -> [String: String] {
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.scheme == "https")
        #expect(parts.host == "github.com")
        #expect(parts.path == "/manaflow-ai/cmux/issues/new")
        return Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func opensTheBugFormWithAMarkerTheReconcilerCounts() throws {
        let fields = try query(SendFeedbackURL.iPhone(appVersion: "1.2 (345)", systemVersion: "26.1"))
        #expect(fields["template"] == "bug_report.yml")
        let additional = try #require(fields["additional"])
        #expect(additional.lowercased().contains("sent from cmux next send feedback"))
        #expect(additional.contains("iPhone"))
    }

    @Test func fillsTheVersionsThePhoneKnows() throws {
        let fields = try query(SendFeedbackURL.iPhone(appVersion: "1.2 (345)", systemVersion: "26.1"))
        #expect(fields["cmux-version"] == "1.2 (345) (iPhone app)")
        #expect(fields["macos-version"] == "Not a Mac: sent from iOS 26.1")
        #expect(fields["area"] == "ios")
    }

    @Test func aPlusInAVersionStaysAPlus() throws {
        let url = SendFeedbackURL.iPhone(appVersion: "1.2+dev", systemVersion: "26.1")
        #expect(url.absoluteString.contains("1.2%2Bdev"))
        #expect(try query(url)["cmux-version"] == "1.2+dev (iPhone app)")
    }
}
