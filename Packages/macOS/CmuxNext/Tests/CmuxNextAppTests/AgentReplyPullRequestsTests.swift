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

    /// Leo 2026-10-20: the card showed "GitHub rate limit · resets 9:11 PM" because every hover
    /// called GitHub. A card reads the cache and says how old it is; it never waits on gh.
    @Test func aCardReadsTheCacheAndNeverWaits() async throws {
        let gh = try Self.rig()
        let pullRequests = AgentReplyPullRequests(reader: AgentChatPullRequestReader(gh: gh))
        // Nothing read yet: the answer is empty and comes back at once.
        #expect(pullRequests.answer(Self.url).pullRequest == nil)
        #expect(await pullRequests.read(Self.url)?.number == 7)
        let answer = pullRequests.answer(Self.url)
        #expect(answer.pullRequest?.number == 7)
        #expect((answer.fetchedAt ?? 0) > 1_700_000_000)
        #expect(answer.reading == false)
        // Ten more hovers of the same link are no more calls.
        for _ in 0..<10 { _ = pullRequests.answer(Self.url) }
        #expect(Self.calls(gh) == 1)
    }

    /// A read that fails (no gh, no network, a rate limit) keeps the last good answer, so the
    /// card goes on showing the pull request with its age instead of an error.
    @Test func afailedReadKeepsTheLastGoodAnswer() async throws {
        let gh = try Self.rig()
        let pullRequests = AgentReplyPullRequests(reader: AgentChatPullRequestReader(gh: gh),
                                                  freshness: .zero, retry: .zero)
        #expect(await pullRequests.read(Self.url)?.number == 7)
        let good = pullRequests.answer(Self.url).fetchedAt
        // gh now fails the way a rate limit does: no output, nonzero status.
        try "#!/bin/sh\nexit 1\n".write(toFile: gh, atomically: true, encoding: .utf8)
        #expect(await pullRequests.read(Self.url)?.number == 7)
        let after = pullRequests.answer(Self.url)
        #expect(after.pullRequest?.number == 7)
        #expect(after.fetchedAt == good)
    }

    /// The links a reply shows are read when the page inspects them, so the data is there before
    /// a card opens, and at most ``AgentReplyPullRequests/maximumRegistered`` at a time.
    @Test func registeringAReplysLinksReadsThemOnce() async throws {
        let gh = try Self.rig()
        let pullRequests = AgentReplyPullRequests(reader: AgentChatPullRequestReader(gh: gh))
        pullRequests.register([Self.url, Self.url])
        #expect(await pullRequests.read(Self.url)?.number == 7)
        #expect(Self.calls(gh) == 1)
    }
}
