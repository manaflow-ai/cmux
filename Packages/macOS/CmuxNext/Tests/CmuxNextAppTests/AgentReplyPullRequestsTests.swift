@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import Foundation
import Testing

/// A pull request link's hover card reads that pull request with the user's GitHub CLI
/// (`gh pr view <url> --json …`), never prompting, and keeps the answer a minute so hovering the
/// same link again asks nothing. A script stands in for `gh` and records each ask.
@MainActor
struct AgentReplyPullRequestsTests {
    private static let url = URL(string: "https://github.com/o/r/pull/7")!
    private static let view = #"{"url":"https://github.com/o/r/pull/7","number":7,"title":"Retry","state":"OPEN","isDraft":true,"author":{"login":"octocat"},"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}"#

    private static func rig() throws -> String {
        let base = FileManager.default.temporaryDirectory.appending(path: "reply-pr-\(UUID().uuidString)").path
        let gh = base + "/gh"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        try view.write(toFile: base + "/view.json", atomically: true, encoding: .utf8)
        let script = """
            #!/bin/sh
            echo "$*" >> "$0.calls"
            [ "$*" = "pr view \(url.absoluteString) --json \(AgentPanePullRequest.fields)" ] || exit 2
            cat "$(dirname "$0")/view.json"
            """
        try script.write(toFile: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
        return gh
    }

    private static func calls(_ gh: String) -> Int {
        ((try? String(contentsOfFile: gh + ".calls", encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    @Test func readsThePullRequestByItsLink() async throws {
        let gh = try Self.rig()
        let read = try #require(await AgentChatPullRequestReader(gh: gh).read(url: Self.url))
        #expect(read.title == "Retry")
        #expect(read.state == "draft")
        #expect(read.author == "octocat")
        #expect(read.checks == .init(state: "passing", passed: 1, total: 1))
    }

    @Test func asksOnceAMinute() async throws {
        let gh = try Self.rig()
        let pullRequests = AgentReplyPullRequests(reader: AgentChatPullRequestReader(gh: gh))
        #expect(await pullRequests.read(Self.url)?.number == 7)
        #expect(await pullRequests.read(Self.url)?.number == 7)
        #expect(Self.calls(gh) == 1)
    }
}
