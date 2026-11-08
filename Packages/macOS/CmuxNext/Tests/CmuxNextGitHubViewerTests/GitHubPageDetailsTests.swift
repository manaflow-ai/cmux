import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextGitHubViewer

/// The GitHub page's richer half (Leo, 2026-11-07): the body and conversation read once per
/// pull request, one file's diff for its inline expand, and Merge, which goes through GitHub's
/// normal path pinned to the head the page showed and only on a person's click.
@MainActor
@Suite
struct GitHubPageDetailsTests {
    private static let page = PageCallContext(page: "cmux.github")
    private static let click = PageCallContext(page: "cmux.github", userGesture: true, gestureEvent: 1)
    private static let pull = URL(string: "https://github.com/manaflow-ai/cmux/pull/36002")!
    nonisolated private static let head = String(repeating: "ab", count: 20)

    private final class Calls: @unchecked Sendable { // crash-allow: test log touched only on the main actor
        var reads = 0
        var merges: [(String, String)] = []
    }

    private static func cache() -> AgentReplyPullRequests {
        AgentReplyPullRequests(reader: AgentChatPullRequestReader(gh: "/nonexistent/gh", environment: [:]))
    }

    nonisolated private static let answer = #"""
        {"data": {"repository": {"viewerDefaultMergeMethod": "SQUASH", "pullRequest": {
          "body": "## Summary\nFixes it.", "headRefOid": "\#(head)", "mergeStateStatus": "UNSTABLE",
          "labels": {"nodes": [{"name": "risk:normal", "color": "FBCA04"}, {"name": "odd", "color": "nothex"}]},
          "comments": {"totalCount": 3, "nodes": [
            {"author": {"login": "lawrence"}, "body": "Second", "createdAt": "2026-11-07T03:00:00Z", "url": "https://github.com/manaflow-ai/cmux/pull/36002#issuecomment-2"},
            {"author": {"login": "leo"}, "body": "First", "createdAt": "2026-11-07T01:00:00Z", "url": "https://evil.example/x"}]},
          "reviews": {"totalCount": 2, "nodes": [
            {"author": {"login": "bot"}, "state": "COMMENTED", "body": "", "submittedAt": "2026-11-07T02:00:00Z", "comments": {"nodes": []}},
            {"author": {"login": "austin"}, "state": "CHANGES_REQUESTED", "body": "One thing", "submittedAt": "2026-11-07T02:30:00Z",
             "url": "https://github.com/manaflow-ai/cmux/pull/36002#pullrequestreview-9",
             "comments": {"nodes": [{"path": "a.swift", "line": null, "originalLine": 12, "body": "Here", "url": null}]}}]},
          "reviewRequests": {"nodes": [{"requestedReviewer": {"__typename": "User", "login": "austin"}}, {"requestedReviewer": {"__typename": "Team", "name": "core"}}]},
          "latestOpinionatedReviews": {"nodes": [{"author": {"login": "austin"}, "state": "CHANGES_REQUESTED"}, {"author": {"login": "lawrence"}, "state": "APPROVED"}]},
          "closingIssuesReferences": {"nodes": [{"number": 7, "title": "Broken", "url": "https://github.com/manaflow-ai/cmux/issues/7", "state": "OPEN"}]}
        }}}}
        """#

    @Test func theDetailsReadKeepsTheConversationInTimeOrder() throws {
        let details = try #require(GitHubPullRequestDetails.parse(Data(Self.answer.utf8)))
        #expect(details.body == "## Summary\nFixes it.")
        #expect(details.headCommit == Self.head)
        #expect(details.mergeState == "unstable")
        #expect(details.mergeMethod == "squash")
        #expect(details.labels == [.init(name: "risk:normal", color: "fbca04"), .init(name: "odd", color: "")])
        // Oldest first; the empty "commented" review is left out.
        #expect(details.conversation.map(\.body) == ["First", "One thing", "Second"])
        #expect(details.conversation.first?.url == nil, "only github.com links are kept")
        #expect(details.conversation[1].state == "changes_requested")
        #expect(details.conversation[1].comments == [.init(path: "a.swift", line: 12, body: "Here", url: nil)])
        #expect(details.conversationTotal == 5)
        // Asked again after reviewing: requested, not "changes requested".
        #expect(details.reviewers.map(\.name) == ["lawrence", "austin", "core"])
        #expect(details.reviewers.map(\.state) == ["approved", "requested", "requested"])
        #expect(details.linked.map(\.number) == [7])
        #expect(GitHubPullRequestDetails.parse(Data(#"{"data": {"repository": null}}"#.utf8)) == nil)
    }

    /// GitHub's own rendering of each body goes to the page beside its Markdown (Leo, 2026-11-07: "is it
    /// possible to, like, just add the rendering for the links"), whole or not at all.
    @Test func eachBodyCarriesGitHubsRenderingWholeOrNotAtAll() throws {
        #expect(GitHubPullRequestDetails.query.contains("body bodyHTML headRefOid"))
        #expect(GitHubPullRequestDetails.query.components(separatedBy: "bodyHTML").count - 1 == 4)
        let long = String(repeating: "x", count: GitHubPullRequestDetails.maximumHTML + 1)
        let answer = #"""
            {"data": {"repository": {"pullRequest": {"body": "Hi", "bodyHTML": "<p>Hi</p>", "headRefOid": "",
              "comments": {"totalCount": 1, "nodes": [{"author": {"login": "bot"}, "body": "b", "bodyHTML": "\#(long)", "createdAt": "2026-11-07T01:00:00Z"}]},
              "reviews": {"totalCount": 1, "nodes": [{"author": {"login": "rabbit"}, "state": "COMMENTED", "body": "r",
                "bodyHTML": "<details><summary>More</summary><p>r</p></details>", "submittedAt": "2026-11-07T02:00:00Z",
                "comments": {"nodes": [{"path": "a.yml", "line": 3, "body": "c", "bodyHTML": "<p><sup>c</sup></p>"}]}}]}
            }}}}
            """#
        let details = try #require(GitHubPullRequestDetails.parse(Data(answer.utf8)))
        #expect(details.html == "<p>Hi</p>")
        #expect(details.conversation.map(\.html) == ["", "<details><summary>More</summary><p>r</p></details>"])
        #expect(details.conversation[1].comments.first?.html == "<p><sup>c</sup></p>")
        let json = details.json
        #expect(json["html"]?.stringValue == "<p>Hi</p>")
        guard case .array(let entries)? = json["conversation"], entries.count == 2,
              case .array(let inline)? = entries[1]["comments"], let first = inline.first else {
            Issue.record("the conversation's JSON lost its shape")
            return
        }
        #expect(first["html"]?.stringValue == "<p><sup>c</sup></p>")
    }

    /// The conversation's filters: "Mine" needs the signed-in login, "Unresolved" each review comment's thread.
    @Test func theReadCarriesTheViewerAndEachThreadsState() throws {
        #expect(GitHubPullRequestDetails.query.contains("viewer { login }"))
        #expect(GitHubPullRequestDetails.query.contains("reviewThreads(last: 100) { nodes { isResolved"))
        let open = "https://github.com/manaflow-ai/cmux/pull/1#discussion_r1"
        let done = "https://github.com/manaflow-ai/cmux/pull/1#discussion_r2"
        let answer = #"""
            {"data": {"viewer": {"login": "teamleaderleo"}, "repository": {"pullRequest": {"body": "", "headRefOid": "",
              "reviews": {"totalCount": 1, "nodes": [{"author": {"login": "rabbit"}, "state": "COMMENTED", "body": "",
                "submittedAt": "2026-11-07T02:00:00Z", "comments": {"nodes": [
                  {"path": "a.yml", "line": 3, "body": "open", "url": "\#(open)"},
                  {"path": "a.yml", "line": 9, "body": "done", "url": "\#(done)"},
                  {"path": "b.yml", "line": 1, "body": "unknown", "url": null}]}}]},
              "reviewThreads": {"nodes": [
                {"isResolved": false, "comments": {"nodes": [{"url": "\#(open)"}]}},
                {"isResolved": true, "comments": {"nodes": [{"url": "\#(done)"}]}}]}
            }}}}
            """#
        let details = try #require(GitHubPullRequestDetails.parse(Data(answer.utf8)))
        #expect(details.viewer == "teamleaderleo")
        #expect(details.conversation.first?.comments.map(\.resolved) == [false, true, nil])
        #expect(details.json["viewer"]?.stringValue == "teamleaderleo")
    }

    @Test func oneReadSendsAtMostItsHTMLBudgetTheDescriptionAndNewestFirst() throws {
        // Each body fits its own cap; together they pass the read's budget.
        let size = GitHubPullRequestDetails.maximumHTML - 10
        let each = GitHubPullRequestDetails.maximumTotalHTML / size + 2
        let big = String(repeating: "x", count: size)
        let comments = (0..<each).map { index in
            #"{"author": {"login": "bot"}, "body": "b", "bodyHTML": "\#(big)", "createdAt": "2026-11-07T\#(String(format: "%02d", index)):00:00Z"}"#
        }.joined(separator: ",")
        let answer = #"""
            {"data": {"repository": {"pullRequest": {"body": "Hi", "bodyHTML": "\#(big)", "headRefOid": "",
              "comments": {"totalCount": \#(each), "nodes": [\#(comments)]}}}}}
            """#
        let details = try #require(GitHubPullRequestDetails.parse(Data(answer.utf8)))
        #expect(details.html == big)
        let sent = details.html.utf8.count + details.conversation.reduce(0) { $0 + $1.html.utf8.count }
        #expect(sent <= GitHubPullRequestDetails.maximumTotalHTML)
        // The newest keep theirs; the oldest draw their Markdown.
        #expect(details.conversation.last?.html == big)
        #expect(details.conversation.first?.html == "")
        #expect(details.conversation.count == each)
    }

    @Test func theDetailsAreReadOncePerPullRequestHoweverOftenThePageAsks() async throws {
        let calls = Calls()
        let provider = GitHubPageProvider(cache: Self.cache(), diffReader: { _ in nil }, detailsReader: { _ in
            await MainActor.run { calls.reads += 1 }
            return GitHubPullRequestDetails.parse(Data(Self.answer.utf8))
        }, openWeb: { _, _ in false }, openDiff: { _, _, _, _ in false })
        for _ in 0..<3 {
            let reply = try await provider.call("cmux.github.pr.details", params: ["url": .string(Self.pull.absoluteString)], context: Self.page)
            #expect(reply["details"]?["headCommit"]?.stringValue == Self.head)
        }
        #expect(calls.reads == 1)
    }

    @Test func aNewUpdatedAtReadsTheDetailsAgainAtOnce() async throws {
        let calls = Calls(), cache = Self.cache()
        let provider = GitHubPageProvider(cache: cache, diffReader: { _ in nil }, detailsReader: { _ in
            await MainActor.run { calls.reads += 1 }
            return GitHubPullRequestDetails.parse(Data(Self.answer.utf8))
        }, openWeb: { _, _ in false }, openDiff: { _, _, _, _ in false })
        let params: JSONValue = ["url": .string(Self.pull.absoluteString)]
        _ = try await provider.call("cmux.github.pr.details", params: params, context: Self.page)
        // A comment lands: the cache's updatedAt moves, so the next ask reads, inside the minute.
        let view = #"{"url": "\#(Self.pull.absoluteString)", "number": 36002, "updatedAt": "2026-11-07T09:00:00Z"}"#
        cache.seed(try #require(AgentPanePullRequest(ghView: Data(view.utf8))), for: Self.pull)
        _ = try await provider.call("cmux.github.pr.details", params: params, context: Self.page)
        _ = try await provider.call("cmux.github.pr.details", params: params, context: Self.page)
        #expect(calls.reads == 2)
    }

    @Test func mergeIsPinnedToTheShownHeadAndNeedsAClick() async throws {
        let calls = Calls()
        let provider = GitHubPageProvider(cache: Self.cache(), diffReader: { _ in nil }, merger: { url, head in
            await MainActor.run { calls.merges.append((url, head)) }
            return .merged(queued: false)
        }, openWeb: { _, _ in false }, openDiff: { _, _, _, _ in false })
        let params: JSONValue = ["url": .string(Self.pull.absoluteString), "head": .string(Self.head)]
        // No click, no merge.
        await #expect(throws: PageError.self) { _ = try await provider.call("cmux.github.pr.merge", params: params, context: Self.page) }
        // A head that is not a full commit id is refused before any merge.
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.github.pr.merge", params: ["url": .string(Self.pull.absoluteString), "head": "main"],
                                        context: Self.click)
        }
        let reply = try await provider.call("cmux.github.pr.merge", params: params, context: Self.click)
        #expect(reply["merged"]?.boolValue == true)
        #expect(calls.merges.count == 1)
        #expect(calls.merges.first?.0 == Self.pull.absoluteString)
        #expect(calls.merges.first?.1 == Self.head)
        // The same click is spent.
        await #expect(throws: PageError.self) { _ = try await provider.call("cmux.github.pr.merge", params: params, context: Self.click) }
        #expect(calls.merges.count == 1)
    }

    @Test func aRefusedMergeSaysGitHubsReason() async throws {
        let provider = GitHubPageProvider(cache: Self.cache(), diffReader: { _ in nil }, merger: { _, _ in .refused("Pull request is not mergeable") },
                                          openWeb: { _, _ in false }, openDiff: { _, _, _, _ in false })
        do {
            _ = try await provider.call("cmux.github.pr.merge", params: ["url": .string(Self.pull.absoluteString), "head": .string(Self.head)],
                                        context: Self.click)
            Issue.record("a refused merge answered")
        } catch let error as PageError {
            #expect(error.code == "cmux.github.merge_refused")
            #expect(error.message == "Pull request is not mergeable")
        }
    }

    @Test func theMergeRefusesWhatGitHubSaysCannotMergeAtTheShownHead() {
        let url = Self.pull.absoluteString
        let open: [String: Any] = ["url": url, "state": "OPEN", "isDraft": false, "headRefOid": Self.head, "mergeStateStatus": "CLEAN"]
        #expect(AgentPaneGitPullRequest.pageMergeRefusal(open, url: url, head: Self.head) == nil)
        // A red check GitHub does not require merges, as on github.com.
        #expect(AgentPaneGitPullRequest.pageMergeRefusal(open.merging(["mergeStateStatus": "UNSTABLE"]) { $1 }, url: url, head: Self.head) == nil)
        for change: [String: Any] in [["headRefOid": String(repeating: "cd", count: 20)], ["state": "MERGED"], ["isDraft": true],
                                      ["mergeStateStatus": "BLOCKED"], ["mergeStateStatus": "BEHIND"], ["mergeStateStatus": "DIRTY"],
                                      ["mergeStateStatus": "UNKNOWN"], ["url": "https://github.com/manaflow-ai/cmux/pull/1"]] {
            #expect(AgentPaneGitPullRequest.pageMergeRefusal(open.merging(change) { $1 }, url: url, head: Self.head) != nil, "\(change)")
        }
    }

    nonisolated private static let diff = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1 +1 @@
        -+++ b/b.swift
        ++new
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        diff --git a/old.md b/new.md
        similarity index 100%
        rename from old.md
        rename to new.md
        diff --git a/b.swift b/b.swift
        --- a/b.swift
        +++ b/b.swift
        @@ -1 +1 @@
        -x
        +y

        """

    @Test func oneFilesPatchIsItsSectionOfTheDiff() throws {
        let a = try #require(GitHubPageProvider.patch(of: "a.swift", in: Self.diff))
        #expect(a.hasPrefix("diff --git a/a.swift b/a.swift\n"))
        #expect(a.hasSuffix("++new\n"))
        // A line of a.swift's text that reads like a header does not make it b.swift's.
        #expect(GitHubPageProvider.patch(of: "b.swift", in: Self.diff)?.hasSuffix("-x\n+y\n") == true)
        #expect(GitHubPageProvider.patch(of: "gone.txt", in: Self.diff)?.contains("-bye") == true)
        #expect(GitHubPageProvider.patch(of: "new.md", in: Self.diff)?.contains("rename to new.md") == true)
        #expect(GitHubPageProvider.patch(of: "missing", in: Self.diff) == nil)
    }

    @Test func aFileExpandedInlineReadsTheDiffKeptForThePage() async throws {
        let calls = Calls()
        let provider = GitHubPageProvider(cache: Self.cache(), diffReader: { _ in
            await MainActor.run { calls.reads += 1 }
            return Self.diff
        }, openWeb: { _, _ in false }, openDiff: { _, _, _, _ in false })
        let url = JSONValue.string(Self.pull.absoluteString)
        let a = try await provider.call("cmux.github.diff.file", params: ["url": url, "file": "a.swift"], context: Self.page)
        let b = try await provider.call("cmux.github.diff.file", params: ["url": url, "file": "b.swift"], context: Self.page)
        let none = try await provider.call("cmux.github.diff.file", params: ["url": url, "file": "nope"], context: Self.page)
        #expect(a["patch"]?.stringValue?.contains("++new") == true)
        #expect(b["patch"]?.stringValue?.contains("+y") == true)
        #expect(none["patch"]?.isNull == true)
        // One diff read for every file the page expands.
        #expect(calls.reads == 1)
    }
}
