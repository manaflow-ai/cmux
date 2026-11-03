import CmuxNextBrowser
import CmuxNextCrashReporting
import Foundation

/// The restart notice's Report button (crash program phase 2): a prefilled
/// GitHub issue the user reads and sends themselves. It holds the version,
/// the commit, the bundle id, the cause (exception name and reason, or the
/// signal), the exception's symbol frames, and `CrashReportDetails`: macOS's
/// report of the crash (exception codes and faulting address, the crashed
/// thread's frames, uptime, file name) and what the run was doing. Never a
/// path under the home folder, a URL, a title or terminal text.
nonisolated struct CrashIssueReport: Equatable, Sendable {
    static let newIssue = "https://github.com/manaflow-ai/cmux/issues/new"
    static let frameLimit = 20
    /// GitHub answers 414 past about 8 KB of URL: frames and actions shrink until the URL fits.
    static let urlLimit = 7_500

    let title: String
    let body: String

    init(previous: PreviousRun, version: String, bundleID: String, osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
         commit: String? = nil, system: SystemCrashReport? = nil, systemReportName: String? = nil,
         executableFunction: @escaping CrashReportDetails.ExecutableFunction = { _, _, _ in nil }, home: String = NSHomeDirectory()) {
        let cause = Self.cause(of: previous, home: home)
        let title = "cmux-next crash: \(cause ?? "unknown cause")"
        self.title = title
        let details = CrashReportDetails(system: system, systemReportName: systemReportName, context: previous.context,
                                         launched: previous.launched, executableFunction: executableFunction, home: home)
        var lines = [
            "cmux-next quit unexpectedly.",
            "",
            "- Version: \(version)",
            "- Commit: \(commit ?? "unknown")",
            "- Bundle: \(bundleID)",
            "- macOS: \(osVersion)",
            "- Cause: \(cause ?? "unknown (no signal or exception recorded)")",
            "- Restart after a restart: \(previous.recovery ? "yes" : "no")",
        ] + details.summary()
        if let frames = previous.exception?.frames, !frames.isEmpty {
            lines += ["", "Exception frames:", "```"] + frames.prefix(Self.frameLimit).map { Self.scrub($0, home: home) } + ["```"]
        }
        let ending = ["", "What were you doing when it happened?", ""]
        var body = ""
        for (frames, actions) in [(Self.frameLimit, CrashContext.actionLimit), (12, 8), (8, 5), (4, 3), (0, 0)] {
            body = (lines + details.blocks(frames: frames, actions: actions) + ending).joined(separator: "\n")
            if (Self.url(title: title, body: body)?.absoluteString.count ?? 0) <= Self.urlLimit { break }
        }
        self.body = body
    }

    /// One line: the exception summary, else the signal name.
    static func cause(of previous: PreviousRun, home: String = NSHomeDirectory()) -> String? {
        if let exception = previous.exception { return scrub(exception.summary, home: home) }
        guard let signal = previous.signal else { return nil }
        return BrowserProcessExit(reason: .crashed, code: Int(signal)).codeDescription ?? "signal \(signal)"
    }

    /// The issue page with the title and body filled in.
    var url: URL? { Self.url(title: title, body: body) }

    private static func url(title: String, body: String) -> URL? {
        var components = URLComponents(string: Self.newIssue)
        components?.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
        return components?.url
    }

    /// Replaces the home folder path with `~`.
    static func scrub(_ text: String, home: String = NSHomeDirectory()) -> String {
        home.isEmpty ? text : text.replacingOccurrences(of: home, with: "~")
    }
}
