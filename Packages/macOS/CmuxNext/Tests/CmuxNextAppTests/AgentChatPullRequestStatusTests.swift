@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import Foundation
import Testing

/// The PR chip's status popover (cx-ncc.77.1, Codex desktop's PR status): the App reads the pull
/// request's title, review decision, mergeability and each check from the GitHub CLI, asks again
/// when a turn ends, and runs gh with the user's GitHub settings. A script stands in for `gh`.
@MainActor
struct AgentChatPullRequestStatusTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static let fields = AgentPanePullRequest.fields
    private static let view = """
        {"url":"https://github.com/o/r/pull/7","number":7,"title":"Stage single hunks","state":"OPEN","isDraft":false,
         "reviewDecision":"CHANGES_REQUESTED","mergeable":"MERGEABLE","createdAt":"2026-10-01T09:30:00Z","mergedAt":null,
         "statusCheckRollup":[
         {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.com/o/r/actions/runs/1"},
         {"__typename":"StatusContext","context":"ci/lint","state":"SUCCESS","targetUrl":"https://ci.example/2"},
         {"__typename":"CheckRun","name":"test","status":"IN_PROGRESS","conclusion":"","detailsUrl":"javascript:alert(1)"}]}
        """

    /// A folder and a fake `gh` that records its arguments and the GitHub settings it was given,
    /// and prints `view` when run there with the expected arguments.
    private static func rig() throws -> (folder: String, gh: String) {
        let base = FileManager.default.temporaryDirectory.appending(path: "header-pr-status-\(UUID().uuidString)").path
        let folder = base + "/repo", gh = base + "/gh"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try view.write(toFile: base + "/view.json", atomically: true, encoding: .utf8)
        let script = """
            #!/bin/sh
            echo "$*" >> "$0.calls"
            echo "token=$GH_TOKEN host=$GH_HOST config=$GH_CONFIG_DIR proxy=$HTTPS_PROXY other=$UNRELATED_SECRET" > "$0.env"
            [ "$(pwd -P)" = "$(cd '\(folder)' && pwd -P)" ] || exit 3
            [ "$*" = "pr view --json \(fields)" ] || exit 2
            cat "$(dirname "$0")/view.json"
            """
        try script.write(toFile: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
        return (folder, gh)
    }

    private static func calls(_ gh: String) -> Int {
        ((try? String(contentsOfFile: gh + ".calls", encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    /// The popover's facts: the title, the review decision, whether it can merge, and each check
    /// with its own state and an https link (a link that is not https is dropped).
    @Test func readsTheTitleReviewAndEachCheck() async throws {
        let rig = try Self.rig()
        let read = try #require(await AgentChatPullRequestReader(gh: rig.gh).read(in: rig.folder))
        #expect(read.title == "Stage single hunks")
        #expect(read.review == "changes_requested")
        #expect(read.mergeable == "mergeable")
        #expect(read.checks == .init(state: "failing", passed: 1, total: 3))
        #expect(read.checkList == [
            .init(name: "build", state: "failed", url: "https://github.com/o/r/actions/runs/1"),
            .init(name: "test", state: "pending", url: nil),
            .init(name: "ci/lint", state: "passed", url: "https://ci.example/2"),
        ])
        let json = AgentPaneHeaderState.with(read).json.compactText
        #expect(json.contains(#""title":"Stage single hunks""#))
        #expect(json.contains(#""name":"build""#))
    }

    /// When the pull request was opened and, once merged, when it merged, as GitHub gives them:
    /// cycle time runs between the two, and both come from the same gh call (hq#1920).
    @Test func readsWhenItWasOpenedAndMerged() async throws {
        let rig = try Self.rig()
        let open = try #require(await AgentChatPullRequestReader(gh: rig.gh).read(in: rig.folder))
        let openJSON = AgentPaneHeaderState.with(open).json.compactText
        #expect(openJSON.contains(#""createdAt":"2026-10-01T09:30:00Z""#))
        #expect(openJSON.contains("\"mergedAt\":\"\""))
        #expect(Self.calls(rig.gh) == 1)
        let merged = try #require(AgentPanePullRequest(ghView: Data(#"""
            {"url":"https://github.com/o/r/pull/9","number":9,"state":"MERGED","isDraft":false,
             "createdAt":"2026-10-01T09:30:00Z","mergedAt":"2026-10-02T11:00:00Z","statusCheckRollup":[]}
            """#.utf8)))
        #expect(merged.json.compactText.contains(#""mergedAt":"2026-10-02T11:00:00Z""#))
    }

    /// gh runs with the user's GitHub token, host, config folder and proxy, so a token-only or
    /// proxied setup gets its chip; nothing else from the App's environment reaches it.
    @Test func ghGetsTheUsersGitHubSettings() async throws {
        let rig = try Self.rig()
        let reader = AgentChatPullRequestReader(gh: rig.gh, environment: [
            "GH_TOKEN": "t0k", "GH_HOST": "ghe.example", "GH_CONFIG_DIR": "/cfg", "HTTPS_PROXY": "http://proxy:3128",
            "UNRELATED_SECRET": "no", "HOME": NSHomeDirectory(),
        ])
        _ = await reader.read(in: rig.folder)
        let env = try String(contentsOfFile: rig.gh + ".env", encoding: .utf8)
        #expect(env == "token=t0k host=ghe.example config=/cfg proxy=http://proxy:3128 other=\n")
    }

    /// A turn's end (`pane.tabState {refresh: true}`) asks gh again even while the last answer is
    /// fresh, so a PR the agent just created or pushed to shows at once.
    @Test func aTurnEndAsksAgain() async throws {
        let rig = try Self.rig()
        let pullRequests = AgentChatPullRequest(reader: AgentChatPullRequestReader(gh: rig.gh))
        let model = AgentPaneModel(host: NoHost())
        var hooks = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState.with(pullRequests.badge(cwd: rig.folder)) })
        hooks.refreshPullRequest = { pullRequests.askAgain() }
        model.header = hooks
        _ = await model.respond(to: AgentPaneRequest(body: ["method": "pane.tabState"]))
        for _ in 0..<200 where pullRequests.badge(cwd: rig.folder) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Self.calls(rig.gh) == 1)
        _ = await model.respond(to: AgentPaneRequest(body: ["method": "pane.tabState"]))
        #expect(Self.calls(rig.gh) == 1)
        _ = await model.respond(to: AgentPaneRequest(body: ["method": "pane.tabState", "params": ["refresh": true]]))
        for _ in 0..<200 where Self.calls(rig.gh) < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Self.calls(rig.gh) == 2)
    }
}

extension AgentPaneHeaderState {
    /// A header state showing `pullRequest`.
    static func with(_ pullRequest: AgentPanePullRequest?) -> AgentPaneHeaderState {
        var state = AgentPaneHeaderState()
        state.pullRequest = pullRequest
        return state
    }
}
