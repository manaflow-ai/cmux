import Foundation

/// Settings > Send feedback on the iPhone: cmux's bug report form, as the Mac's Help > Send Feedback opens it, with
/// the Additional context field carrying the app marker. HQ counts a report by that marker in the issue body
/// (feedback_fix.py MARKER, "Sent from cmux NEXT Send Feedback"), so the iPhone's text starts with it and then says
/// which phone and app sent it. The form's macOS, chip and install fields describe the Mac the iPhone pairs with.
public enum FeedbackFormLink {
    /// The words HQ's reconciler looks for; the Mac's StaticURL.feedback sends exactly these.
    public static let marker = "Sent from cmux NEXT Send Feedback"

    /// The form URL. `appVersion` also fills the form's required "cmux version" field.
    public static func url(appVersion: String, build: String, osVersion: String) -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "github.com"
        parts.path = "/manaflow-ai/cmux/issues/new"
        parts.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "cmux-version", value: "\(appVersion) (\(build)) iPhone app"),
            URLQueryItem(name: "additional", value: "\(marker) (iPhone, iOS \(osVersion))"),
        ]
        // URLComponents leaves "+" bare in a query value, which GitHub reads as a space; nothing here should carry
        // one, but encode it so a version such as "1.0+tag" reads back intact.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }
}
