import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// `server ensure --restore-progress` prints a progress line every 5 s while the session owner restores. The app
/// reads each one as the child writes it (`ProcessRunner.run(stdoutLine:)`) and publishes the latest in
/// `EnsureOutcome.restoring`, so the launch window and the sidebar say "Restoring sessions…" instead of only that
/// the service isn't connected (Leo, 2026-11-08: a 30-minute restore).
struct RestoreProgressLinesTests {
    /// The lines the runner's callback got, shared with the test.
    private final class Delivered: Sendable {
        private let lines = Mutex<[String]>([])
        func append(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    private static func progress(_ waitedMs: UInt64, pid: String = "4242") -> String {
        #"{"progress":"restoring","session":"cmux-app","pid":\#(pid),"waited_ms":\#(waitedMs)}"#
    }

    @Test(.timeLimit(.minutes(1))) func stdoutLinesArriveAsWrittenAndTheReplyStaysInTheResult() async throws {
        let lines = Delivered()
        let reply = #"{"status":"running","session":"cmux-app"}"#
        // The last line has no newline: it arrives when the child exits.
        let script = """
        printf '%s\\n' '\(Self.progress(0))'
        sleep 0.3
        printf '%s\\n' '\(Self.progress(5000))'
        printf '%s' '\(reply)'
        """
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                                                 environment: nil, timeout: .seconds(10),
                                                 stdoutLine: { line in lines.append(line) },
                                                 clock: ContinuousClock())
        #expect(result.status == 0)
        #expect(lines.all == [Self.progress(0), Self.progress(5000), reply])
        #expect(String(decoding: result.stdout, as: UTF8.self).hasSuffix(reply), "the reply is no longer in the result")
    }

    @Test func progressLinesParseAndOtherLinesDoNot() throws {
        let at = Date(timeIntervalSince1970: 1_000)
        let report = try #require(RestoreProgressReport.parse(Self.progress(15_000), at: at))
        #expect(report == RestoreProgressReport(session: "cmux-app", pid: 4242, waitedMs: 15_000, updatedAt: at))
        #expect(RestoreProgressReport.parse(Self.progress(0, pid: "null"))?.pid == nil, "an owner whose pid is not known yet")
        #expect(RestoreProgressReport.parse(#"{"status":"running","session":"cmux-app","pid":1}"#) == nil)
        #expect(RestoreProgressReport.parse(#"{"progress":"upload","session":"s","waited_ms":1}"#) == nil)
        #expect(RestoreProgressReport.parse("not json") == nil)
    }

    @Test func onlyTheLatestEnsurePublishesAndItsEndClears() throws {
        let outcome = EnsureOutcome()
        let first = outcome.restoreReporter()
        first.line(Self.progress(0))
        #expect(outcome.restoring?.waitedMs == 0)
        first.line(#"{"status":"running","session":"cmux-app","socket":"/s","pid":4242,"generation":"g"}"#)
        #expect(outcome.restoring?.waitedMs == 0, "the reply is not a progress line")
        let second = outcome.restoreReporter()
        first.line(Self.progress(9_000))
        first.end()
        #expect(outcome.restoring?.waitedMs == 0, "an earlier ensure's late line or end changed the report")
        second.line(Self.progress(5_000))
        #expect(outcome.restoring?.waitedMs == 5_000)
        second.end()
        #expect(outcome.restoring == nil, "the report outlived its ensure")
    }
}
