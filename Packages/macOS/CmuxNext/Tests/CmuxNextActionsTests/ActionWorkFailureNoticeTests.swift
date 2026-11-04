@testable import CmuxNextActions
import Foundation
import Testing

/// No daemon error text reaches a toast: a missed deadline shows nothing, a daemon refusal or a dropped connection
/// shows only that the change did not apply, and a reason in the person's words shows as is (Leo, 2026-11-04, on
/// "Move did not apply: set-personal-workspace: timed out: workspace.place (no reply within 2.0 seconds)": "did you
/// encounter this? i dont like chatty unactionable toasts").
@MainActor
@Suite struct ActionWorkFailureNoticeTests {
    private static let slowMove = "set-personal-workspace: timed out: workspace.place (no reply within 2.0 seconds)"

    private static func notices(_ failure: ActionWorkFailure, title: String = "Move") -> [String] {
        let registry = ActionRegistry(catalog: [ActionDescriptor(id: "sidebar.move", title: "Move", category: .other)])
        var shown: [String] = []
        registry.remoteFailureObserver = { _, notice in shown.append(notice) }
        registry.reportFailure(of: "sidebar.move", title: title, failure)
        return shown
    }

    @Test func aMissedDeadlineShowsNoNotice() {
        #expect(Self.notices(ActionWorkFailure(Self.slowMove, mayHaveApplied: true)).isEmpty)
        #expect(Self.notices(ActionWorkFailure(Self.slowMove, terminalMayAppear: true)).isEmpty)
    }

    @Test func aMissedDeadlineOnARunNobodyAwaitsRefusesQuietly() {
        let registry = ActionRegistry(catalog: [])
        var refusals: [(String, Bool)] = []
        registry.refusalObserver = { reason, quiet in refusals.append((reason, quiet)) }
        registry.refuse(failure: ActionWorkFailure(Self.slowMove, mayHaveApplied: true))
        #expect(refusals.count == 1)
        #expect(refusals.first?.1 == true, "a missed deadline showed the refusal HUD")
    }

    @Test func aDaemonRefusalSaysOnlyThatTheChangeDidNotApply() {
        let failure = ActionWorkFailure(log: "set-personal-workspace: workspace.place failed: no workspace matches ws_1 [not_found]")
        #expect(Self.notices(failure) == ["Move did not apply."])
        #expect(failure.notice(title: nil) == "That did not apply.", "a refusal is never silent, and never the daemon's text")
    }

    @Test func aReasonInThePersonsWordsShows() {
        #expect(Self.notices(ActionWorkFailure(log: "new-workspace: disk full [enospc]", reason: "the disk is full"))
            == ["Move did not apply: the disk is full"])
        #expect(ActionWorkFailure(refusal: .unavailable, reason: "This window isn't ready yet.").notice(title: "Move")
            == "This window isn't ready yet.")
        #expect(Self.notices(ActionWorkFailure("the name is taken")) == ["Move did not apply: the name is taken"])
    }

    @Test func aFailureThePersonAlreadySawShowsNothing() {
        var failure = ActionWorkFailure("the pane is still opening")
        failure.shown = true
        #expect(Self.notices(failure).isEmpty)
    }

    /// Every way a daemon failure is built: none of the notices names the op, the command label, a deadline or the
    /// daemon's own text.
    @Test func noNoticeCarriesAnOpNameOrATimeout() {
        let failures = [
            ActionWorkFailure(Self.slowMove, mayHaveApplied: true),
            ActionWorkFailure(log: "update-personal-group: workspace_group.update failed: busy"),
            ActionWorkFailure(log: "new-conversation-tab: timed out", reason: nil),
        ]
        for failure in failures {
            for notice in [failure.notice(title: "Move"), failure.notice(title: nil)].compactMap(\.self) {
                #expect(Self.leaksInternals(notice) == nil, "\(notice) leaks \(Self.leaksInternals(notice) ?? "")")
            }
        }
    }

    /// What in `notice` a person must never read, or nil: an op or command name (`set-personal-workspace`,
    /// `workspace.place`, `workspace_group.update`), "timed out", or a deadline.
    nonisolated static func leaksInternals(_ notice: String) -> String? {
        let patterns = [#"\b[a-z]+(-[a-z]+){1,}\b"#, #"\b[a-z_]+\.[a-z_]+\b"#, #"(?i)timed out"#, #"(?i)no reply within"#,
                        #"\[[a-z_]+\]"#]
        for pattern in patterns {
            if let range = notice.range(of: pattern, options: .regularExpression) { return String(notice[range]) }
        }
        return nil
    }

    /// Sources show an ``ActionWorkFailure`` through `ActionRegistry.refuse(failure:)` or its `notice(title:)`, never
    /// its raw `message` (which names the command and carries the daemon's text).
    @Test func sourcesNeverShowARawFailureMessage() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let raw = try NSRegularExpression(pattern: #"(refuse\(failure\.message\)|refusalHUD\.show\(failure\.message)"#)
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("///") {
                guard raw.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
                // A typed `ActionFailure` caught just above is the person's sentence, not a daemon error.
                if lines[max(0, index - 3)..<index].contains(where: { $0.contains("as ActionFailure") }) { continue }
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        #expect(offenders.isEmpty, "show these through registry.refuse(failure:) or failure.notice(title:): \(offenders)")
    }
}
