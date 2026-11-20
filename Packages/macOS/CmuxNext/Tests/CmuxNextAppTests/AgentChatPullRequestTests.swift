@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import Foundation
import Testing

/// The chat header's pull request chip (cx-tcwj): the App asks the GitHub CLI for the pull request
/// of the chat folder's branch and sums its checks, and the header state carries it to the page. A
/// script stands in for `gh`; it answers only in the chat's folder and records each ask.
@MainActor
struct AgentChatPullRequestTests {
    private static let view = """
        {"url":"https://github.com/o/r/pull/7","number":7,"state":"OPEN","isDraft":false,"statusCheckRollup":[
         {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},
         {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED"},
         {"__typename":"StatusContext","state":"SUCCESS"},
         {"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"},
         {"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":""}]}
        """

    /// A folder and a fake `gh` that prints `view` when run there with the expected arguments.
    private static func rig(view: String = view) throws -> (folder: String, gh: String) {
        let base = FileManager.default.temporaryDirectory.appending(path: "header-pr-\(UUID().uuidString)").path
        let folder = base + "/repo", gh = base + "/gh"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try view.write(toFile: base + "/view.json", atomically: true, encoding: .utf8)
        let script = """
            #!/bin/sh
            echo "$*" >> "$0.calls"
            [ "$(pwd -P)" = "$(cd '\(folder)' && pwd -P)" ] || exit 3
            [ "$*" = "pr view --json \(AgentPanePullRequest.fields)" ] || exit 2
            cat "$(dirname "$0")/view.json"
            """
        try script.write(toFile: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
        return (folder, gh)
    }

    private static func calls(_ gh: String) -> Int {
        ((try? String(contentsOfFile: gh + ".calls", encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    /// Checks sum to the worst: a failure beats one still running; skipped ones are not counted.
    @Test func readsThePullRequestAndSumsItsChecks() async throws {
        let rig = try Self.rig()
        let read = try #require(await AgentChatPullRequestReader(gh: rig.gh).read(in: rig.folder))
        #expect(read.url == "https://github.com/o/r/pull/7")
        #expect(read.number == 7)
        #expect(read.state == "open")
        #expect(read.checks == .init(state: "failing", passed: 2, total: 4))
        let pending = AgentPanePullRequest(ghView: Data(#"{"url":"https://github.com/o/r/pull/8","number":8,"state":"OPEN","isDraft":true,"statusCheckRollup":[{"status":"QUEUED"},{"status":"COMPLETED","conclusion":"SUCCESS"}]}"#.utf8))
        #expect(pending?.state == "draft")
        #expect(pending?.checks == .init(state: "pending", passed: 1, total: 2))
        let merged = AgentPanePullRequest(ghView: Data(#"{"url":"https://github.com/o/r/pull/9","number":9,"state":"MERGED","isDraft":false,"statusCheckRollup":[]}"#.utf8))
        #expect(merged?.checks == .init(state: "none", passed: 0, total: 0))
        #expect(AgentPanePullRequest(ghView: Data(#"{"url":"javascript:alert(1)","number":1,"state":"OPEN"}"#.utf8)) == nil)
    }

    /// The chat's header asks once per folder while the answer is fresh, and shows it when it lands;
    /// a folder with no pull request (gh fails) shows none.
    @Test func theHeaderAsksOnceAndShowsTheAnswer() async throws {
        let rig = try Self.rig()
        let pullRequests = AgentChatPullRequest(reader: AgentChatPullRequestReader(gh: rig.gh))
        #expect(pullRequests.badge(cwd: rig.folder) == nil)
        for _ in 0..<200 where pullRequests.badge(cwd: rig.folder) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(pullRequests.badge(cwd: rig.folder)?.number == 7)
        #expect(Self.calls(rig.gh) == 1)
        #expect(pullRequests.badge(cwd: nil) == nil)
        let elsewhere = FileManager.default.temporaryDirectory.path
        _ = pullRequests.badge(cwd: elsewhere)
        try await Task.sleep(for: .milliseconds(300))
        #expect(pullRequests.badge(cwd: elsewhere) == nil)
    }

    /// While checks run, the chat asks again on its own once the answer is stale, so the dot turns
    /// when they finish even if nothing else changes the header.
    @Test func pendingChecksAreAskedAgain() async throws {
        let rig = try Self.rig(view: #"{"url":"https://github.com/o/r/pull/8","number":8,"state":"OPEN","isDraft":false,"statusCheckRollup":[{"status":"IN_PROGRESS","conclusion":""}]}"#)
        let pullRequests = AgentChatPullRequest(reader: AgentChatPullRequestReader(gh: rig.gh), freshness: .milliseconds(100))
        _ = pullRequests.badge(cwd: rig.folder)
        for _ in 0..<200 where Self.calls(rig.gh) < 3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Self.calls(rig.gh) >= 3)
        #expect(AgentPanePullRequest.checks([["status": "COMPLETED", "conclusion": "STALE"]]).state == "pending")
    }

    /// The header state always names the pull request, `null` when there is none, so the page drops
    /// a chip left from another chat.
    @Test func theHeaderStateCarriesThePullRequestOrNull() {
        var state = AgentPaneHeaderState()
        #expect(state.json.compactText.contains(#""pullRequest":null"#))
        state.pullRequest = AgentPanePullRequest(url: "https://github.com/o/r/pull/7", number: 7, state: "open",
                                                 checks: .init(state: "passing", passed: 2, total: 2))
        #expect(state.json.compactText.contains(#""number":7"#))
        #expect(!state.shows(AgentPaneHeaderState()))
    }
}
