@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import Foundation
import Testing

/// A pull request link's hover card reads that pull request with the user's GitHub CLI, never
/// prompting, and keeps the answer a minute so hovering the same link again asks nothing. The
/// links of a reply are read together, in one `gh api graphql`. A script stands in for `gh` and
/// records each ask.
@MainActor
struct AgentReplyPullRequestsTests {
    private static let url = URL(string: "https://github.com/o/r/pull/7")!
    private static let other = URL(string: "https://github.com/o/r/pull/8")!
    private static let view = #"{"url":"https://github.com/o/r/pull/7","number":7,"title":"Retry","state":"OPEN","isDraft":true,"author":{"login":"octocat"},"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}"#

    /// One pull request as GraphQL answers it: a connection's rows arrive under `nodes`, and the
    /// check rollup hangs off the last commit.
    private static func node(_ number: Int) -> String {
        """
        {"pullRequest":{"url":"https://github.com/o/r/pull/\(number)","number":\(number),"title":"Retry",
        "state":"OPEN","isDraft":false,"updatedAt":"2026-10-20T01:02:03Z","changedFiles":3,
        "baseRefName":"feat-cmux-next","headRefName":"work","additions":12,"deletions":4,"author":{"login":"octocat"},
        "labels":{"nodes":[{"name":"risk:normal"},{"name":"agent"}]},
        "files":{"nodes":[{"path":"webviews/src/a.ts","additions":12,"deletions":4}]},
        "commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
        {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"}]}}}}]}}}
        """.replacingOccurrences(of: "\n", with: "")
    }

    private static func rig() throws -> String {
        let base = FileManager.default.temporaryDirectory.appending(path: "reply-pr-\(UUID().uuidString)").path
        let gh = base + "/gh"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        try view.write(toFile: base + "/view.json", atomically: true, encoding: .utf8)
        try #"{"data":{"p0":\#(node(7)),"p1":\#(node(8))}}"#
            .write(toFile: base + "/graphql.json", atomically: true, encoding: .utf8)
        let script = """
            #!/bin/sh
            echo "$*" >> "$0.calls"
            if [ "$1" = "api" ]; then
              cat "$(dirname "$0")/graphql.json"
              exit 0
            fi
            [ "$*" = "pr view \(url.absoluteString) --json \(AgentPanePullRequest.fields)" ] || exit 2
            cat "$(dirname "$0")/view.json"
            """
        try script.write(toFile: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
        return gh
    }

    private static func callLines(_ gh: String) -> [String] {
        ((try? String(contentsOfFile: gh + ".calls", encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    private static func calls(_ gh: String) -> Int { callLines(gh).count }

    /// How many pull requests every `gh api graphql` call of this rig asked about.
    private static func asked(_ gh: String) -> Int {
        callLines(gh).reduce(0) { $0 + $1.components(separatedBy: "pullRequest(number:").count - 1 }
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
    @Test func aFailedReadKeepsTheLastGoodAnswer() async throws {
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
    /// a card opens — and all of them in one GraphQL read, not one `gh pr view` each. A reply
    /// full of pull request links must cost GitHub one call, not one per link.
    @Test func aReplysLinksAreOneBatchedRead() async throws {
        let gh = try Self.rig()
        let pullRequests = AgentReplyPullRequests(reader: AgentChatPullRequestReader(gh: gh))
        pullRequests.register([Self.url, Self.other, Self.url])
        #expect(await pullRequests.read(Self.url)?.number == 7)
        #expect(await pullRequests.read(Self.other)?.number == 8)
        #expect(Self.calls(gh) == 1)
        #expect(Self.callLines(gh).first?.hasPrefix("api graphql") == true)
    }

    /// The batched read asks for every field a card draws, so a card filled from it is not
    /// missing the branches, labels or files a `gh pr view` of the same link would have.
    @Test func aBatchedReadCarriesTheCardsFields() async throws {
        let gh = try Self.rig()
        let read = try #require(await AgentChatPullRequestReader(gh: gh).read(urls: [Self.url.absoluteString])[Self.url.absoluteString] ?? nil)
        #expect(read.baseRef == "feat-cmux-next")
        #expect(read.headRef == "work")
        #expect(read.labels == ["risk:normal", "agent"])
        #expect(read.changedFiles == 3)
        #expect(read.files == [.init(path: "webviews/src/a.ts", additions: 12, deletions: 4)])
        #expect(read.updatedAt == "2026-10-20T01:02:03Z")
        #expect(read.checks == .init(state: "passing", passed: 1, total: 1))
    }

    /// The fields the fragment asks of the pull request itself: the identifiers at the top level of
    /// `fragment f on PullRequest { … }`, with every nested selection and argument list skipped.
    /// Searching the whole query instead would find a field that is no longer asked of the pull
    /// request — delete the top-level `additions` and `files { nodes { … additions … } }` still
    /// matches, delete `number` and `pullRequest(number:)` still matches — so the guard below has
    /// to read the fragment's own level and nothing else.
    private static func fragmentFields(_ query: String) -> Set<String> {
        guard let start = query.range(of: "fragment f on PullRequest {")?.upperBound else { return [] }
        var fields: Set<String> = []
        var word = ""
        var depth = 0
        var parens = 0
        for character in query[start...] {
            if character.isLetter || character.isNumber || character == "_", depth == 0, parens == 0 {
                word.append(character)
                continue
            }
            if !word.isEmpty, depth == 0, parens == 0 { fields.insert(word) }
            word = ""
            switch character {
            case "(": parens += 1
            case ")": parens -= 1
            case "{": depth += 1
            case "}":
                // The fragment's own closing brace: everything after it belongs to no field.
                if depth == 0 { return fields }
                depth -= 1
            default: break
            }
        }
        return fields
    }

    /// The batched query asks the pull request for every field `gh pr view` would read, so a drift
    /// between the two is caught here instead of by an empty row on a card: the stub gh above
    /// answers its fixture whatever the query says, so only this reads the ask itself.
    @Test func theBatchedQueryAsksForEveryFieldGhReads() throws {
        let target = try #require(AgentChatPullRequestReader.Target(url: Self.url.absoluteString))
        let query = AgentChatPullRequestReader.query([target])
        let fields = Self.fragmentFields(query)
        // The fragment was found and read, and only its own level: `path` is a field of a file.
        #expect(fields.contains("url"))
        #expect(fields.contains("path") == false, "fragmentFields read a nested selection as the pull request's")
        for field in AgentPanePullRequest.fields.split(separator: ",").map(String.init) {
            // The one field that is not a field of a pull request in GraphQL: the rollup hangs off
            // the last commit, and `pullRequests(fromGraphQL:)` reshapes it back.
            let asked = field == "statusCheckRollup" ? "commits" : field
            #expect(fields.contains(asked), "the batched query no longer asks the pull request for \(field)")
        }
        // The arguments of the three connections, which the names above cannot see: `last: 1` is
        // the rollup's commit, and `pullRequests(fromGraphQL:)` reads `nodes.last`, so a
        // `first: 1` here would draw a multi-commit pull request's checks from the wrong commit.
        #expect(query.contains("commits(last: 1)"))
        #expect(query.contains("files(first: 100)"))
        #expect(query.contains("labels(first: \(AgentPanePullRequest.maximumLabels))"))
        // Every context carries the run it came from, on the head's rollup as well as the base's:
        // `AgentPanePullRequest.identity` matches a head check against a base one by its workflow
        // as well as its name, so trimming these fields would quietly degrade the match to the
        // name alone and excuse a red of one workflow with a same-named red of another.
        #expect(query.components(separatedBy: "checkSuite { workflowRun { databaseId workflow { databaseId name } } }").count == 3,
                "the run fields belong to both rollups the query reads")
        // And the base branch's tip is read beside the head's, which is what "also red on base"
        // compares against.
        #expect(query.contains("baseRef { target { ... on Commit { statusCheckRollup {"))
    }

    /// Replies full of links cannot grow the cache without bound: a batch records a whole host
    /// request at once, so dropping one per read left ``AgentReplyPullRequests/maximumKept`` behind.
    @Test func manyRepliesLeaveTheCacheAtItsBound() async throws {
        let gh = try Self.rig()
        let pullRequests = AgentReplyPullRequests(reader: AgentChatPullRequestReader(gh: gh))
        // Twenty requests of a full bound each, through a cache that keeps 200.
        let size = AgentReplyPullRequests.maximumRegistered
        for reply in 0..<20 {
            let batch = (0..<size).compactMap { URL(string: "https://github.com/o/r/pull/\(100 + reply * size + $0)") }
            pullRequests.register(batch)
            // Awaits that reply's one batched read, which records all of its links at once.
            _ = await pullRequests.read(batch[0])
            #expect(pullRequests.kept <= AgentReplyPullRequests.maximumKept)
        }
        #expect(pullRequests.kept == AgentReplyPullRequests.maximumKept)
    }

    /// One `link.inspect` cannot start a hundred reads: ``AgentReplyPullRequests/maximumRegistered``
    /// links are prefetched per request, and the rest are read if and when a card opens.
    @Test func oneHostRequestPrefetchesAtMostItsBound() async throws {
        let gh = try Self.rig()
        let pullRequests = AgentReplyPullRequests(reader: AgentChatPullRequestReader(gh: gh))
        let bound = AgentReplyPullRequests.maximumRegistered
        let many = (1...(bound + 10)).compactMap { URL(string: "https://github.com/o/r/pull/\($0)") }
        pullRequests.register(many)
        // Awaits the register's read, whatever it answered for this link.
        _ = await pullRequests.read(many[0])
        #expect(Self.asked(gh) == bound)
    }

    /// Every link of one host request is prefetched, so no card is left to read its own.
    ///
    /// The page gathers its chips' links across every reply and asks for them in one
    /// `link.inspect` (``AgentPaneReplyRequest/maximumInspect``), so a bound below that number was
    /// a bound on the page, not on the reply: in a chat with more pull request links than it, the
    /// ones past it cost a read each when a card opened them. Covering the whole request costs one
    /// more batched read (64 links at ``AgentChatPullRequestReader/batchSize`` 50 is two), which is
    /// two calls to GitHub for a page instead of one call per card.
    @Test func everyLinkOfOneHostRequestIsPrefetched() async throws {
        let gh = try Self.rig()
        let pullRequests = AgentReplyPullRequests(reader: AgentChatPullRequestReader(gh: gh))
        let whole = (1...AgentPaneReplyRequest.maximumInspect).compactMap {
            URL(string: "https://github.com/o/r/pull/\($0)")
        }
        pullRequests.register(whole)
        _ = await pullRequests.read(whole[0])
        #expect(Self.asked(gh) == AgentPaneReplyRequest.maximumInspect, "the whole request, not a prefix of it")
        let batches = (AgentPaneReplyRequest.maximumInspect + AgentChatPullRequestReader.batchSize - 1)
            / AgentChatPullRequestReader.batchSize
        #expect(Self.calls(gh) == batches, "and in batched reads, never one call per link")
        // The card of the last link of the request waits on nothing and costs no further call.
        #expect(pullRequests.answer(whole[whole.count - 1]).reading == false)
        #expect(Self.calls(gh) == batches)
    }

    /// A cache-only answer (the Inspector's Changes polling many links) starts no read, even for
    /// a link never read or gone stale; only a registration or a card's own ask reads.
    @Test func aCacheOnlyAnswerStartsNoRead() async throws {
        let gh = try Self.rig()
        let pullRequests = AgentReplyPullRequests(reader: AgentChatPullRequestReader(gh: gh),
                                                  freshness: .zero, retry: .zero)
        let none = pullRequests.answer(Self.url, read: false)
        #expect(none.pullRequest == nil)
        #expect(none.reading == false)
        #expect(Self.calls(gh) == 0)
        #expect(await pullRequests.read(Self.url)?.number == 7)
        #expect(Self.calls(gh) == 1)
        // Stale at once (freshness zero), yet a cache-only answer reads nothing.
        #expect(pullRequests.answer(Self.url, read: false).pullRequest?.number == 7)
        #expect(Self.calls(gh) == 1)
    }

    /// An answer says when the read that gave it began, which is no later than when it finished:
    /// a read that began before the chat closed a pull request cannot reopen its row, however long
    /// the batch it rode in took.
    @Test func anAnswerSaysWhenItsReadBegan() async throws {
        let gh = try Self.rig()
        let pullRequests = AgentReplyPullRequests(reader: AgentChatPullRequestReader(gh: gh))
        let before = Date().timeIntervalSince1970
        #expect(await pullRequests.read(Self.url)?.number == 7)
        let answer = pullRequests.answer(Self.url, read: false)
        let readFrom = try #require(answer.readFrom)
        let fetchedAt = try #require(answer.fetchedAt)
        #expect(readFrom >= before)
        #expect(readFrom <= fetchedAt)
    }
}
