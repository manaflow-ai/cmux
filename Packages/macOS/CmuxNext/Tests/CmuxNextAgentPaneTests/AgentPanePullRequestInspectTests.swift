@testable import CmuxNextAgentPane
import Foundation
import Testing

/// A pull request link's hover card (Leo 2026-10-20): the page asks `pr.inspect {url}` for a
/// GitHub pull request it links to, and the host answers with what `gh pr view` says about it,
/// including its author. The URL comes from untrusted reply text, so only a plain
/// `https://github.com/<owner>/<repo>/pull/<n>` is taken, and nothing else rides along.
struct AgentPanePullRequestInspectTests {
    @Test func takesAGitHubPullRequestLink() throws {
        let request = AgentPaneReplyRequest(method: "pr.inspect", params: ["url": "https://github.com/manaflow-ai/leo-workspace/pull/634"])
        #expect(request == .inspectPullRequest(try #require(URL(string: "https://github.com/manaflow-ai/leo-workspace/pull/634"))))
        #expect(request?.isPassive == true)
        // A trailing slash or a tab of the pull request names the same one.
        #expect(AgentPaneReplyRequest(method: "pr.inspect", params: ["url": "https://github.com/o/r/pull/7/"])
            == .inspectPullRequest(try #require(URL(string: "https://github.com/o/r/pull/7"))))
        #expect(AgentPaneReplyRequest(method: "pr.inspect", params: ["url": "https://github.com/o/r/pull/7/files"])
            == .inspectPullRequest(try #require(URL(string: "https://github.com/o/r/pull/7"))))
    }

    @Test func refusesAnythingElse() {
        for url in [
            "http://github.com/o/r/pull/7",
            "https://evil.example/o/r/pull/7",
            "https://github.com.evil.example/o/r/pull/7",
            "https://user:secret@github.com/o/r/pull/7",
            "https://github.com/o/r/issues/7",
            "https://github.com/o/r/pull/7x",
            "https://github.com/o/r/pull/-1",
            "https://github.com/o/r/pull/7?x=--web",
            "https://github.com/-o/r/pull/7",
            "https://github.com/o/r",
            "--web",
            "",
        ] {
            #expect(AgentPaneReplyRequest(method: "pr.inspect", params: ["url": url]) == nil, "\(url)")
        }
        #expect(AgentPaneReplyRequest(method: "pr.inspect", params: ["url": "https://github.com/o/r/pull/7", "repo": "x"]) == nil)
        #expect(AgentPaneReplyRequest(method: "pr.inspect", params: [:]) == nil)
    }

    @Test func readsTheAuthor() throws {
        let view = #"{"url":"https://github.com/o/r/pull/7","number":7,"title":"Retry","state":"MERGED","author":{"login":"octocat","name":"Mona"},"statusCheckRollup":[]}"#
        let pullRequest = try #require(AgentPanePullRequest(ghView: Data(view.utf8)))
        #expect(pullRequest.author == "octocat")
        #expect(pullRequest.state == "merged")
        #expect(AgentPanePullRequest.fields.split(separator: ",").contains("author"))
        let json = try #require(pullRequest.json.foundationObject as? [String: Any])
        #expect(json["author"] as? String == "octocat")
    }

    @MainActor @Test func answersWithWhatTheHostReads() throws {
        let links = AgentPaneReplyLinks()
        var asked: [URL] = []
        links.pullRequest = { url in
            asked.append(url)
            return AgentPanePullRequestAnswer(
                pullRequest: AgentPanePullRequest(url: url.absoluteString, number: 7, title: "Retry", state: "open",
                                                  checks: .init(state: "passing", passed: 2, total: 2),
                                                  baseRef: "main", headRef: "fix", author: "octocat"),
                fetchedAt: 1_760_000_000)
        }
        let url = try #require(URL(string: "https://github.com/o/r/pull/7"))
        let reply = links.respondToPullRequest(url)
        #expect(asked == [url])
        let value = try #require(reply["value"] as? [String: Any])
        let pullRequest = try #require(value["pullRequest"] as? [String: Any])
        #expect(pullRequest["title"] as? String == "Retry")
        #expect(pullRequest["author"] as? String == "octocat")
        #expect(pullRequest["baseRef"] as? String == "main")
        #expect(pullRequest["headRef"] as? String == "fix")
        // The card says how old the answer is instead of showing a rate-limit message.
        #expect(value["fetchedAt"] as? Double == 1_760_000_000)
        #expect(value["reading"] as? Bool == false)
        links.pullRequest = { _ in AgentPanePullRequestAnswer(reading: true) }
        let none = try #require(links.respondToPullRequest(url)["value"] as? [String: Any])
        #expect(none["pullRequest"] is NSNull)
        #expect(none["fetchedAt"] == nil)
        #expect(none["reading"] as? Bool == true)
    }
}
