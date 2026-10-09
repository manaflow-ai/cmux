import CmuxNextBrowser
import Foundation

/// The restart notice's Report button (crash program phase 2): a prefilled
/// GitHub issue the user reads and sends themselves. It holds the version,
/// the bundle id, the cause (exception name and reason, or the signal) and
/// the exception's symbol frames; never a path under the home folder, a URL,
/// a title or terminal text.
nonisolated struct CrashIssueReport: Equatable, Sendable {
    static let newIssue = "https://github.com/manaflow-ai/cmux/issues/new"
    static let frameLimit = 20

    let title: String
    let body: String

    init(previous: PreviousRun, version: String, bundleID: String, osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString) {
        let cause = Self.cause(of: previous)
        title = "cmux-next crash: \(cause ?? "unknown cause")"
        var lines = [
            "cmux-next quit unexpectedly.",
            "",
            "- Version: \(version)",
            "- Bundle: \(bundleID)",
            "- macOS: \(osVersion)",
            "- Cause: \(cause ?? "unknown (no signal or exception recorded)")",
            "- Restart after a restart: \(previous.recovery ? "yes" : "no")",
        ]
        if let frames = previous.exception?.frames, !frames.isEmpty {
            lines += ["", "Exception frames:", "```"] + frames.prefix(Self.frameLimit).map { Self.scrub($0) } + ["```"]
        }
        lines += ["", "What were you doing when it happened?", ""]
        body = lines.joined(separator: "\n")
    }

    /// One line: the exception summary, else the signal name.
    static func cause(of previous: PreviousRun) -> String? {
        if let exception = previous.exception { return scrub(exception.summary) }
        guard let signal = previous.signal else { return nil }
        return BrowserProcessExit(reason: .crashed, code: Int(signal)).codeDescription ?? "signal \(signal)"
    }

    /// The issue page with the title and body filled in.
    var url: URL? {
        var components = URLComponents(string: Self.newIssue)
        components?.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
        return components?.url
    }

    /// Replaces the home folder path with `~`.
    static func scrub(_ text: String, home: String = NSHomeDirectory()) -> String {
        home.isEmpty ? text : text.replacingOccurrences(of: home, with: "~")
    }
}
