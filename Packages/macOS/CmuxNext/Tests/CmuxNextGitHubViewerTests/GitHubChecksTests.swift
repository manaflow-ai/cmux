import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextGitHubViewer

/// The GitHub page's CI dashboard (Leo, 2026-11-07: "here's your big dashboard"): every job at
/// the head with a re-run's earlier attempt dropped, the ETA from the base's durations, one shared
/// read kept for a time set by the state, a failed job's step and log read once per job, and
/// Re-run failed only for runs the page showed failing and only on a click.
@MainActor
@Suite
struct GitHubChecksTests {
    private static let page = PageCallContext(page: "cmux.github")
    private static let click = PageCallContext(page: "cmux.github", userGesture: true, gestureEvent: 1)
    private static let pull = URL(string: "https://github.com/manaflow-ai/cmux/pull/37210")!
    private static var link: GitHubLink { GitHubLink(pull)! }

    private final class Calls: @unchecked Sendable { // crash-allow: test log touched only on the main actor
        var reads = 0
        var failures: [Int] = []
        var reruns: [Int] = []
    }

    nonisolated private static let answer = #"""
        {"data": {"repository": {"pullRequest": {"headRefOid": "abc",
          "commits": {"nodes": [{"commit": {
            "checkSuites": {"nodes": [
              {"workflowRun": {"databaseId": 11, "workflow": {"name": "ci"}}, "checkRuns": {"nodes": [
                {"databaseId": 1, "name": "health (0)", "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": "2026-11-07T08:00:00Z", "completedAt": "2026-11-07T08:02:00Z", "detailsUrl": "https://github.com/x/1"},
                {"databaseId": 2, "name": "health (1)", "status": "IN_PROGRESS", "conclusion": null, "startedAt": "2026-11-07T08:00:00Z", "completedAt": null},
                {"databaseId": 3, "name": "test", "status": "COMPLETED", "conclusion": "FAILURE", "startedAt": "2026-11-07T08:00:00Z", "completedAt": "2026-11-07T08:05:00Z"},
                {"databaseId": 4, "name": "journey", "status": "QUEUED", "conclusion": null, "startedAt": null, "completedAt": null}]}},
              {"workflowRun": {"databaseId": 12, "workflow": {"name": "ci"}}, "checkRuns": {"nodes": [
                {"databaseId": 5, "name": "test", "status": "COMPLETED", "conclusion": "FAILURE", "startedAt": "2026-11-07T07:00:00Z", "completedAt": "2026-11-07T07:05:00Z"}]}}]},
            "status": {"contexts": [{"context": "risk evidence", "state": "SUCCESS", "targetUrl": null, "createdAt": "2026-11-07T08:00:00Z"}]}}}]},
          "baseRef": {"target": {"checkSuites": {"nodes": [
            {"workflowRun": {"workflow": {"name": "ci"}}, "checkRuns": {"nodes": [
              {"name": "health (1)", "conclusion": "SUCCESS", "startedAt": "2026-11-07T06:00:00Z", "completedAt": "2026-11-07T06:03:00Z"}]}}]}}}
        }}}}
        """#

    @Test func theJobsKeepTheLatestAttemptAndTheBasesDuration() throws {
        let checks = try #require(GitHubChecks.parse(Data(Self.answer.utf8)))
        #expect(checks.jobs.map(\.name) == ["health (0)", "health (1)", "test", "journey", "risk evidence"])
        #expect(checks.jobs.map(\.state) == ["passed", "running", "failed", "queued", "passed"])
        // The older run's "test" (run 12, an hour earlier) is not the one shown.
        #expect(checks.jobs[2].id == 3)
        #expect(checks.jobs[2].run == 11)
        #expect(checks.jobs[1].expected == 180)
        #expect(checks.jobs[0].expected == nil)
        #expect(!checks.settled)
        #expect(checks.freshness == .seconds(20))
        #expect(GitHubChecks(head: "", jobs: [checks.jobs[0]]).freshness == .seconds(300))
    }

    @Test func aFailedJobsExcerptEndsAtItsLastErrorWithoutTimestamps() {
        let log = (1...40).map { "2026-11-07T08:01:\(String(format: "%02d", $0 % 60)).1234567Z line \($0)" }
            + ["2026-11-07T08:02:00.0000000Z ##[error]Process completed with exit code 1.", "2026-11-07T08:02:01.0000000Z Post job cleanup."]
        let excerpt = GitHubJobFailure.excerpt(of: Data(log.joined(separator: "\n").utf8))
        let lines = excerpt.split(separator: "\n")
        #expect(lines.count == GitHubJobFailure.maximumLines)
        #expect(lines.last == "Process completed with exit code 1.")
        #expect(lines.first == "line 18")
        #expect(!excerpt.contains("Post job cleanup"))
        let job = #"{"steps": [{"name": "Set up", "conclusion": "success"}, {"name": "Run tests", "conclusion": "failure"}]}"#
        #expect(GitHubJobFailure.failingStep(Data(job.utf8)) == "Run tests")
    }

    private func provider(_ calls: Calls, checks: GitHubChecksCache) -> GitHubPageProvider {
        GitHubPageProvider(cache: AgentReplyPullRequests(reader: AgentChatPullRequestReader(gh: "/nonexistent/gh", environment: [:])),
                           diffReader: { _ in nil }, checks: checks, rerunner: { _, run in
                               await MainActor.run { calls.reruns.append(run) }
                               return nil
                           }, openWeb: { _, _ in false }, openDiff: { _, _, _, _ in false })
    }

    private func cache(_ calls: Calls) -> GitHubChecksCache {
        GitHubChecksCache(reader: { _ in
            await MainActor.run { calls.reads += 1 }
            return GitHubChecks.parse(Data(Self.answer.utf8))
        }, failureReader: { _, job in
            await MainActor.run { calls.failures.append(job) }
            return GitHubJobFailure(step: "Run tests", excerpt: "boom")
        })
    }

    @Test func pagesShareOneReadAndAFailureIsReadOncePerJob() async throws {
        let calls = Calls(), checks = cache(calls)
        let one = provider(calls, checks: checks), two = provider(calls, checks: checks)
        let params: JSONValue = ["url": .string(Self.pull.absoluteString)]
        for provider in [one, two, one, two] {
            _ = try await provider.call("cmux.github.checks.read", params: params, context: Self.page)
        }
        await checks.settle()
        let reply = try await one.call("cmux.github.checks.read", params: params, context: Self.page)
        // Four pages' asks within the freshness: one GitHub read, one failure read for the one failed job.
        #expect(calls.reads == 1)
        #expect(calls.failures == [3])
        let failed = reply["checks"]?["jobs"]?.arrayValue?.first { $0["state"]?.stringValue == "failed" }
        #expect(failed?["failure"]?["step"]?.stringValue == "Run tests")
        #expect(failed?["failure"]?["excerpt"]?.stringValue == "boom")
    }

    @Test func reRunFailedTakesOnlyShownFailedRunsAndAClick() async throws {
        let calls = Calls(), checks = cache(calls)
        let provider = provider(calls, checks: checks)
        let url = JSONValue.string(Self.pull.absoluteString)
        _ = try await provider.call("cmux.github.checks.read", params: ["url": url], context: Self.page)
        // No click, no re-run.
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.github.checks.rerun", params: ["url": url, "runs": .array([.number(11)])], context: Self.page)
        }
        // A run the page did not show failing (12 was the older attempt) is refused.
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.github.checks.rerun", params: ["url": url, "runs": .array([.number(12)])], context: Self.click)
        }
        #expect(calls.reruns.isEmpty)
        let reply = try await provider.call("cmux.github.checks.rerun", params: ["url": url, "runs": .array([.number(11)])], context: Self.click)
        #expect(reply["rerun"]?.intValue == 1)
        #expect(calls.reruns == [11])
        // The kept answer is stale now: the next ask starts a read (in the background, as the kept one draws).
        _ = try await provider.call("cmux.github.checks.read", params: ["url": url], context: Self.page)
        #expect(checks.reads == 2)
    }
}
