import Foundation

/// Settings > Send feedback opens cmux's bug report form, as the Mac's Help > Send Feedback does
/// (CmuxNextAppCore `StaticURL.feedback`), with every field the iPhone knows filled in.
///
/// HQ's reconciler (cmuxterm-hq `tools/fleet-reconcilers/feedback_fix.py`) counts a report by `marker` in its
/// body, a case-insensitive substring match. The iPhone's text starts with the Mac's, so the reconciler counts both,
/// and the "(iPhone)" suffix tells them apart.
///
/// The form (cmux main `.github/ISSUE_TEMPLATE/bug_report.yml`) also requires a macOS version, a Mac chip and an
/// install method. An iPhone report has no macOS version, so that field gets the iOS version, written as such. The
/// two dropdowns describe the Mac the phone pairs with, so the reporter picks them. The form can only change on
/// cmux main.
public enum SendFeedbackURL {
    public static let marker = "Sent from cmux NEXT Send Feedback (iPhone)"

    /// The bug form's URL. `appVersion`: "1.2 (345)", the version shown in Settings' footer. `systemVersion`:
    /// "26.1", from `UIDevice.current.systemVersion`.
    public static func iPhone(appVersion: String, systemVersion: String) -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "github.com"
        parts.path = "/manaflow-ai/cmux/issues/new"
        parts.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "cmux-version", value: "\(appVersion) (iPhone app)"),
            URLQueryItem(name: "macos-version", value: "Not a Mac: sent from iOS \(systemVersion)"),
            URLQueryItem(name: "area", value: "ios"),
            URLQueryItem(name: "additional", value: marker),
        ]
        // URLComponents leaves "+" as is, and GitHub reads a query "+" as a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }
}
