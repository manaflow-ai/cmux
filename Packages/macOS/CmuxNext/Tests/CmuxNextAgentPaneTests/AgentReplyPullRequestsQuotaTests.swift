@testable import CmuxNextAgentPane
import Foundation
import os
import Testing

/// The hover card's reads spend the user's own GitHub quota (Leo 2026-11-07: "I assume this goes
/// from what the individual user pulls, and so that uses their GitHub quota... batch it ... using
/// it at a good pace so to not starve it"). A fake GitHub answers every `gh api graphql` from a
/// small world of pull requests and logs each call, and an injected clock runs half an hour of a
/// chat in a moment.
@MainActor
struct AgentReplyPullRequestsQuotaTests {
    /// One call the fake answered: a probe or a full read, and the pull requests it asked about.
    nonisolated struct Call: Equatable, Sendable {
        var probe: Bool
        var numbers: [Int]
    }

    nonisolated struct Pull: Sendable {
        var state: String
        var updatedAt = "2026-11-07T00:00:00Z"
        var rollup = "SUCCESS"
        var avatar: String?
    }

    /// GitHub for the tests: the probe and the full read of `pulls`, and the rate limit.
    actor FakeGitHub {
        var pulls: [Int: Pull]
        var remaining = 4000
        var resetAt = "2030-01-01T00:00:00Z"
        private(set) var log: [Call] = []

        init(_ pulls: [Int: Pull]) { self.pulls = pulls }

        func change(_ number: Int, rollup: String? = nil, updatedAt: String? = nil) {
            if let rollup { pulls[number]?.rollup = rollup }
            if let updatedAt { pulls[number]?.updatedAt = updatedAt }
        }

        func limit(remaining: Int, resetAt: String) {
            self.remaining = remaining
            self.resetAt = resetAt
        }

        func answer(_ arguments: [String]) -> Data? {
            guard arguments.prefix(2) == ["api", "graphql"],
                  let query = arguments.first(where: { $0.hasPrefix("query=") }) else { return nil }
            let probe = !query.contains("fragment f on PullRequest")
            let numbers = query.components(separatedBy: "issueOrPullRequest(number: ").dropFirst().compactMap { part in Int(part.prefix(while: \.isNumber)) }
            log.append(Call(probe: probe, numbers: numbers))
            var members = numbers.enumerated().map { index, number in
                let node = pulls[number].map { probe ? Self.probeNode($0) : Self.fullNode(number, $0) } ?? "null"
                return "\"p\(index)\":{\"issueOrPullRequest\":\(node)}"
            }
            members.append("\"rateLimit\":{\"limit\":5000,\"remaining\":\(remaining),\"resetAt\":\"\(resetAt)\",\"cost\":1}")
            return Data("{\"data\":{\(members.joined(separator: ","))}}".utf8)
        }

        nonisolated private static func rollupNode(_ pull: Pull, contexts: Bool) -> String {
            guard contexts else { return "{\"state\":\"\(pull.rollup)\"}" }
            let check = pull.rollup == "PENDING"
                ? "{\"__typename\":\"CheckRun\",\"name\":\"build\",\"status\":\"IN_PROGRESS\",\"conclusion\":null}"
                : "{\"__typename\":\"CheckRun\",\"name\":\"build\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"}"
            return "{\"state\":\"\(pull.rollup)\",\"contexts\":{\"nodes\":[\(check)]}}"
        }

        nonisolated private static func probeNode(_ pull: Pull) -> String {
            "{\"updatedAt\":\"\(pull.updatedAt)\",\"state\":\"\(pull.state)\",\"isDraft\":false,"
                + "\"commits\":{\"nodes\":[{\"commit\":{\"statusCheckRollup\":\(rollupNode(pull, contexts: false))}}]}}"
        }

        nonisolated private static func fullNode(_ number: Int, _ pull: Pull) -> String {
            let avatar = pull.avatar.map { ",\"avatarUrl\":\"\($0)\"" } ?? ""
            return "{\"url\":\"https://github.com/o/r/pull/\(number)\",\"number\":\(number),\"title\":\"PR \(number)\","
                + "\"state\":\"\(pull.state)\",\"isDraft\":false,\"updatedAt\":\"\(pull.updatedAt)\","
                + "\"author\":{\"login\":\"octocat\"\(avatar)},"
                + "\"labels\":{\"nodes\":[{\"name\":\"bug\",\"color\":\"d73a4a\"},{\"name\":\"odd\",\"color\":\"#d73a4a\"}]},"
                + "\"files\":{\"nodes\":[]},"
                + "\"commits\":{\"nodes\":[{\"commit\":{\"statusCheckRollup\":\(rollupNode(pull, contexts: true))}}]}}"
        }
    }

    /// The clock the cache reads: `elapsed` past a fixed start.
    final class FakeTime {
        let start = ContinuousClock.now
        var elapsed: Duration = .zero
        static let epoch: TimeInterval = 1_800_000_000

        var date: Date { Date(timeIntervalSince1970: Self.epoch + Double(elapsed.components.seconds)) }

        var now: AgentReplyPullRequests.Now {
            AgentReplyPullRequests.Now(instant: { [unowned self] in self.start + self.elapsed }, date: { [unowned self] in self.date })
        }
    }

    private static func url(_ number: Int) -> URL {
        URL(string: "https://github.com/o/r/pull/\(number)") ?? URL(fileURLWithPath: "/")
    }

    nonisolated private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])

    private static func cache(_ github: FakeGitHub, _ time: FakeTime, calls: AgentChatPullRequestReader.Calls = .init(),
                              rules: AgentReplyPullRequests.Rules = .current,
                              avatars: AgentReplyAvatars = AgentReplyAvatars(fetch: { _ in nil })) -> AgentReplyPullRequests {
        var reader = AgentChatPullRequestReader()
        reader.runner = { arguments, _ in await github.answer(arguments) }
        reader.calls = calls
        return AgentReplyPullRequests(reader: reader, settled: AgentReplyPullRequests.settledFreshness, rules: rules,
                                      now: time.now, avatars: avatars)
    }

    // MARK: - The measure

    /// Thirty pull request links in a chat: 1-8 open with checks running, 9-16 open and settled,
    /// 17-24 merged, 25-30 closed. The page registers every link every two minutes (its
    /// `link.inspect` as replies arrive) and the person hovers ten of them (1, 2, 3, 9, 10, 11, 17,
    /// 18, 25, 26) every thirty seconds, for thirty minutes. Meanwhile #1's checks finish (minute
    /// 5, no `updatedAt` change), #9 gets a push (minute 10) and #2's checks finish (minute 20).
    private static func simulateChat(_ rules: AgentReplyPullRequests.Rules) async -> AgentChatPullRequestReader.Calls.Counts {
        var pulls: [Int: Pull] = [:]
        for number in 1...30 {
            switch number {
            case 1...8: pulls[number] = Pull(state: "OPEN", rollup: "PENDING")
            case 9...16: pulls[number] = Pull(state: "OPEN")
            case 17...24: pulls[number] = Pull(state: "MERGED")
            default: pulls[number] = Pull(state: "CLOSED")
            }
        }
        let github = FakeGitHub(pulls)
        let time = FakeTime()
        let calls = AgentChatPullRequestReader.Calls()
        let cache = Self.cache(github, time, calls: calls, rules: rules)
        let links = (1...30).map(url)
        let hovered = [1, 2, 3, 9, 10, 11, 17, 18, 25, 26].map(url)
        for step in 0..<60 {
            time.elapsed = .seconds(30 * step)
            switch step {
            case 10: await github.change(1, rollup: "SUCCESS")
            case 20: await github.change(9, rollup: "PENDING", updatedAt: "2026-11-07T00:10:00Z")
            case 40: await github.change(2, rollup: "SUCCESS")
            default: break
            }
            if step.isMultiple(of: 4) { cache.register(links) }
            for link in hovered { _ = cache.answer(link) }
            await cache.idle()
        }
        // Every change reached the cache within a minute.
        #expect(cache.answer(url(1), read: false).pullRequest?.rollupState == "SUCCESS")
        #expect(cache.answer(url(2), read: false).pullRequest?.rollupState == "SUCCESS")
        #expect(cache.answer(url(9), read: false).pullRequest?.updatedAt == "2026-11-07T00:10:00Z")
        return calls.counts
    }

    /// The before-and-after number for the quota work. Before: every stale hover was its own full
    /// read, and merged and closed pull requests went stale every minute like open ones — 15
    /// registrations at one read each plus 15 rounds of 10 hover reads, 165 calls. After: one
    /// batched read to start, then one probe a minute for the 16 open links (29), and a full read
    /// only for the three that changed — 33 calls, a fifth of the old.
    @Test func aChatsCallsBeforeAndAfter() async {
        let before = await Self.simulateChat(.legacy)
        let after = await Self.simulateChat(.current)
        #expect(before == .init(reads: 165, probes: 0, views: 0))
        #expect(after == .init(reads: 4, probes: 29, views: 0))
        #expect(after.total * 5 == before.total)
    }

    // MARK: - Freshness and the probe

    /// A merged or closed answer stays fresh an hour; an open one a minute.
    @Test func aSettledPullRequestStaysFreshAnHour() async {
        let github = FakeGitHub([1: Pull(state: "OPEN"), 2: Pull(state: "MERGED"), 3: Pull(state: "CLOSED")])
        let time = FakeTime()
        let cache = Self.cache(github, time)
        cache.register([1, 2, 3].map(Self.url))
        await cache.idle()
        time.elapsed = .seconds(61)
        cache.register([1, 2, 3].map(Self.url))
        await cache.idle()
        time.elapsed = .seconds(3601)
        cache.register([1, 2, 3].map(Self.url))
        await cache.idle()
        #expect(await github.log == [Call(probe: false, numbers: [1, 2, 3]), Call(probe: true, numbers: [1]),
                                     Call(probe: true, numbers: [1, 2, 3])])
    }

    /// A stale answer is probed first, all stale links in one call; only the one whose
    /// `updatedAt` moved, and the open one whose checks finished without moving it, are read again.
    @Test func aProbeReadsOnlyWhatChanged() async {
        let github = FakeGitHub([1: Pull(state: "OPEN"), 2: Pull(state: "OPEN"), 3: Pull(state: "OPEN", rollup: "PENDING"),
                                 4: Pull(state: "OPEN")])
        let time = FakeTime()
        let calls = AgentChatPullRequestReader.Calls()
        let cache = Self.cache(github, time, calls: calls)
        let links = [1, 2, 3, 4].map(Self.url)
        cache.register(links)
        await cache.idle()
        await github.change(2, updatedAt: "2026-11-07T01:00:00Z")
        await github.change(3, rollup: "SUCCESS")
        time.elapsed = .seconds(61)
        // A card's hover: its own link and every other stale one a page asked for lately.
        _ = cache.answer(links[0])
        await cache.idle()
        // The ride-along links come in the cache's own order, so the calls compare as sets.
        let log = await github.log
        #expect(log.count == 3)
        #expect(log.map(\.probe) == [false, true, false])
        #expect(log.map { Set($0.numbers) } == [[1, 2, 3, 4], [1, 2, 3, 4], [2, 3]])
        #expect(calls.counts == .init(reads: 2, probes: 1, views: 0))
        #expect(cache.answer(links[1], read: false).pullRequest?.updatedAt == "2026-11-07T01:00:00Z")
        #expect(cache.answer(links[2], read: false).pullRequest?.checks.state == "passing")
        // An unchanged link is fresh again from the probe.
        #expect(cache.answer(links[3], read: false).fetchedAt == FakeTime.epoch + 61)
    }

    /// The probe asks for an open pull request's rollup and for nothing more of a settled one.
    @Test func theProbeAsksChecksOnlyOfTheOpenOnes() throws {
        let open = try #require(AgentChatPullRequestReader.Target(url: "https://github.com/o/r/pull/1"))
        let merged = try #require(AgentChatPullRequestReader.Target(url: "https://github.com/o/r/pull/2"))
        let query = AgentChatPullRequestReader.probeQuery([(open, true), (merged, false)])
        #expect(query.contains("p0: repository(owner: \"o\", name: \"r\") { issueOrPullRequest(number: 1) { __typename ... on PullRequest { updatedAt state isDraft mergeable commits(last: 1)"))
        #expect(query.contains("p1: repository(owner: \"o\", name: \"r\") { issueOrPullRequest(number: 2) { __typename ... on PullRequest { updatedAt state isDraft mergeable } ... on Issue { updatedAt state stateReason } } }"))
        #expect(query.contains(AgentChatPullRequestReader.rateLimitField))
        // The rollup's sum and its counts by state, never the checks themselves.
        #expect(query.contains("contexts(first: 1) { checkRunCountsByState") && !query.contains("nodes { __typename"), "the probe reads the rollup's sum and counts, never its checks")
        #expect(query.contains("checkRunCountsByState"))
        #expect(query.contains("baseRef"), "an open one's base tip is asked too")
        #expect(query.filter { $0 == "{" }.count == query.filter { $0 == "}" }.count)
        #expect(AgentChatPullRequestReader.query([open]).contains(AgentChatPullRequestReader.rateLimitField))
    }

    // MARK: - The rate budget

    /// Review of #37571 at 3548ad60: a probe that finds a change but leaves the budget under the
    /// hard floor does not spend what is left on the full read; the link keeps its answer.
    @Test func aProbeUnderTheHardFloorDoesNotFollowWithAFullRead() async {
        let github = FakeGitHub([1: Pull(state: "OPEN")])
        let time = FakeTime()
        let calls = AgentChatPullRequestReader.Calls()
        let cache = Self.cache(github, time, calls: calls)
        let link = Self.url(1)
        let resetAt = Date(timeIntervalSince1970: FakeTime.epoch + 3600).formatted(.iso8601)
        cache.register([link])
        await cache.idle()
        #expect(calls.counts.reads == 1)
        await github.change(1, updatedAt: "2026-11-07T00:10:00Z")
        await github.limit(remaining: 50, resetAt: resetAt)
        time.elapsed = .seconds(61)
        _ = cache.answer(link)
        await cache.idle()
        #expect(calls.counts.probes == 1)
        #expect(calls.counts.reads == 1, "no full read under the hard floor")
        #expect(cache.answer(link, read: false).pullRequest != nil)
    }

    /// Review of #37571 at 664acfbe: a batch that reports the points under the hard floor is the
    /// last one sent, for a read and for a probe alike.
    @Test func noBatchIsSentAfterOneReportsThePointsUnderTheFloor() async {
        let numbers = Array(1...64)
        let github = FakeGitHub(Dictionary(uniqueKeysWithValues: numbers.map { ($0, Pull(state: "OPEN")) }))
        await github.limit(remaining: 50, resetAt: Date(timeIntervalSince1970: FakeTime.epoch + 3600).formatted(.iso8601))
        var reader = AgentChatPullRequestReader()
        reader.runner = { arguments, _ in await github.answer(arguments) }
        let urls = numbers.map { Self.url($0).absoluteString }
        _ = await reader.readBatch(urls: urls)
        #expect(await github.log.count == 1)
        _ = await reader.probe(urls, checks: [])
        #expect(await github.log.count == 2)
    }

    /// Under the soft floor the cache stops prefetching and a card reads only its own link, once
    /// per its freshness; under the hard floor it reads nothing until the limit resets.
    @Test func underTheRateFloorsItBacksOff() async {
        let github = FakeGitHub([1: Pull(state: "OPEN"), 2: Pull(state: "OPEN")])
        let time = FakeTime()
        let calls = AgentChatPullRequestReader.Calls()
        let cache = Self.cache(github, time, calls: calls)
        let links = [1, 2].map(Self.url)
        let resetAt = Date(timeIntervalSince1970: FakeTime.epoch + 3600).formatted(.iso8601)
        await github.limit(remaining: 400, resetAt: resetAt)
        cache.register(links)
        await cache.idle()
        #expect(cache.budget.last?.remaining == 400)
        // Soft floor: no prefetch.
        time.elapsed = .seconds(61)
        cache.register(links)
        await cache.idle()
        #expect(calls.counts.total == 1)
        // A card still reads, only its own link, and only once per freshness.
        _ = cache.answer(links[0])
        await cache.idle()
        _ = cache.answer(links[0])
        await cache.idle()
        #expect(await github.log.last == Call(probe: true, numbers: [1]))
        #expect(calls.counts.total == 2)
        // Hard floor: nothing at all, a card included, until the reset.
        await github.limit(remaining: 50, resetAt: resetAt)
        _ = cache.answer(links[1])
        await cache.idle()
        #expect(cache.budget.last?.remaining == 50)
        #expect(calls.counts.total == 3)
        time.elapsed = .seconds(200)
        _ = cache.answer(links[0])
        cache.register(links)
        await cache.idle()
        #expect(calls.counts.total == 3)
        // Past the reset the points have refilled.
        time.elapsed = .seconds(3601)
        _ = cache.answer(links[0])
        await cache.idle()
        #expect(calls.counts.total == 4)
    }

    @Test func theBudgetsFloors() {
        let reset = Date(timeIntervalSince1970: FakeTime.epoch + 3600)
        let before = Date(timeIntervalSince1970: FakeTime.epoch)
        let budget = { (remaining: Int) in
            AgentReplyPullRequests.Budget(last: .init(limit: 5000, remaining: remaining, resetAt: reset))
        }
        #expect(AgentReplyPullRequests.Budget().allows(background: true, at: before))
        #expect(budget(500).allows(background: true, at: before))
        #expect(budget(499).allows(background: true, at: before) == false)
        #expect(budget(499).allows(background: false, at: before))
        #expect(budget(99).allows(background: false, at: before) == false)
        #expect(budget(0).allows(background: true, at: reset))
        #expect(AgentReplyPullRequests.Budget.softFloor(10_000) == 1000)
    }

    // MARK: - Checks finishing under a pending rollup

    /// Review of #37571 at 1eac536b: one check after another finishes while the rollup stays
    /// `PENDING` and `updatedAt` stays put, so a probe of the sum alone renewed stale counts as
    /// fresh. The counts by state are part of what the probe compares.
    @Test func aCheckThatFinishesUnderAPendingRollupIsAChange() throws {
        func rollup(_ running: Int, _ passed: Int) -> [String: Any] {
            ["state": "PENDING", "counts": ["checkRunCountsByState": [["state": "IN_PROGRESS", "count": running],
                                                                     ["state": "SUCCESS", "count": passed]],
                                            "statusContextCountsByState": [[String: Any]]()]]
        }
        let before = AgentChatPullRequestReader.rollupFingerprint(rollup(3, 5))
        let after = AgentChatPullRequestReader.rollupFingerprint(rollup(2, 6))
        #expect(before == "PENDING IN_PROGRESS:3,SUCCESS:5|")
        #expect(before != after)
        #expect(AgentChatPullRequestReader.rollupFingerprint(["state": "success"]) == "SUCCESS")
        #expect(AgentChatPullRequestReader.rollupFingerprint(nil) == "")
        let held = AgentPanePullRequest(url: "https://github.com/o/r/pull/1", number: 1, state: "open", checks: .init(state: "pending", passed: 5, total: 8),
                                        updatedAt: "2026-11-07T00:00:00Z", rollupState: before)
        let probe = AgentChatPullRequestReader.Probe(updatedAt: "2026-11-07T00:00:00Z", state: "open", rollupState: after)
        #expect(AgentReplyPullRequests.changed(held, probe))
        #expect(!AgentReplyPullRequests.changed(held, .init(updatedAt: held.updatedAt, state: "open", rollupState: before)))
        // Conflicts found as the base moved, with nothing else changed (review of #37571 at 664acfbe).
        #expect(AgentReplyPullRequests.changed(held, .init(updatedAt: held.updatedAt, state: "open", rollupState: before,
                                                           mergeable: "conflicting")))
        #expect(AgentChatPullRequestReader.mergeable("UNKNOWN") == "")
        #expect(AgentChatPullRequestReader.mergeable("CONFLICTING") == "conflicting")
        // Base CI moved under an unchanged head (review of #37571 at 3548ad60): "already red on base" may change.
        #expect(AgentReplyPullRequests.changed(held, .init(updatedAt: held.updatedAt, state: "open", rollupState: before,
                                                           baseRollupState: "FAILURE CHECK_RUN:1|")))
    }

    // MARK: - Label colors

    @Test func labelColorsAreSixHexDigitsOrNothing() throws {
        let view = """
            {"url":"https://github.com/o/r/pull/7","number":7,"state":"OPEN","labels":[
            {"name":"bug","color":"d73a4a"},{"name":"Upper","color":"A2EEEF"},{"name":"hash","color":"#d73a4a"},
            {"name":"short","color":"fff"},{"name":"word","color":"zzzzzz"},{"name":"wide","color":"\u{FF11}\u{FF12}\u{FF13}\u{FF14}\u{FF15}\u{FF16}"},
            {"name":"number","color":123456},{"name":"none"},{"name":"bug","color":"000000"}]}
            """
        let pullRequest = try #require(AgentPanePullRequest(ghView: Data(view.utf8)))
        #expect(pullRequest.labelColors == ["bug": "d73a4a", "Upper": "A2EEEF"])
        let json = try #require(pullRequest.json.foundationObject as? [String: Any])
        #expect(json["labelColors"] as? [String: String] == ["bug": "d73a4a", "Upper": "A2EEEF"])
        // None valid: no field, so the card draws colors of its own.
        let plain = try #require(AgentPanePullRequest(ghView: Data(#"{"url":"https://github.com/o/r/pull/7","number":7,"labels":[{"name":"a"}]}"#.utf8)))
        #expect(plain.labelColors.isEmpty)
        #expect((plain.json.foundationObject as? [String: Any])?["labelColors"] == nil)
    }

    @Test func aBatchedReadCarriesLabelColorsAndTheAvatarLink() async {
        let github = FakeGitHub([7: Pull(state: "OPEN", avatar: "https://avatars.githubusercontent.com/u/1?s=48&v=4")])
        var reader = AgentChatPullRequestReader()
        reader.runner = { arguments, _ in await github.answer(arguments) }
        let read = await reader.readBatch(urls: [Self.url(7).absoluteString])
        let pullRequest = read.answers[Self.url(7).absoluteString] ?? nil
        #expect(pullRequest?.labels == ["bug", "odd"])
        #expect(pullRequest?.labelColors == ["bug": "d73a4a"])
        #expect(pullRequest?.authorAvatarURL == "https://avatars.githubusercontent.com/u/1?s=48&v=4")
        #expect(pullRequest?.rollupState == "SUCCESS")
        #expect(read.rate == .init(limit: 5000, remaining: 4000, resetAt: Date(timeIntervalSince1970: 1_893_456_000)))
    }

    // MARK: - Avatars

    @Test func anAvatarLoadsOnlyFromGitHubsAvatarHost() throws {
        #expect(AgentReplyAvatars.allowedURL("https://avatars.githubusercontent.com/u/1?s=48&v=4") != nil)
        for address in ["http://avatars.githubusercontent.com/u/1", "https://evil.example/u/1",
                        "https://avatars.githubusercontent.com.evil.example/u/1", "https://user@avatars.githubusercontent.com/u/1",
                        "https://avatars.githubusercontent.com:8443/u/1", "https://AVATARS.githubusercontent.com/u/1",
                        "//avatars.githubusercontent.com/u/1", "", "data:image/png;base64,AAAA"] {
            #expect(AgentReplyAvatars.allowedURL(address) == nil, "\(address)")
        }
        // A pull request whose avatar link is anywhere else keeps none, and no load starts.
        let view = #"{"url":"https://github.com/o/r/pull/7","number":7,"author":{"login":"octocat","avatarUrl":"https://evil.example/a.png"}}"#
        let elsewhere = try #require(AgentPanePullRequest(ghView: Data(view.utf8)))
        #expect(elsewhere.authorAvatarURL == "")
        let fetches = OSAllocatedUnfairLock(initialState: 0)
        let avatars = AgentReplyAvatars(fetch: { _ in fetches.withLock { $0 += 1 }; return Self.png })
        #expect(avatars.image(login: "octocat", address: "https://evil.example/a.png") == nil)
        #expect(fetches.withLock { $0 } == 0)
    }

    @Test func anAvatarIsAnImageOfItsRealTypeAndSmall() {
        #expect(AgentReplyAvatars.dataURL(Self.png) == "data:image/png;base64," + Self.png.base64EncodedString())
        #expect(AgentReplyAvatars.dataURL(Data([0xFF, 0xD8, 0xFF, 0xE0]))?.hasPrefix("data:image/jpeg;base64,") == true)
        #expect(AgentReplyAvatars.dataURL(Data("GIF89a..".utf8))?.hasPrefix("data:image/gif;base64,") == true)
        #expect(AgentReplyAvatars.dataURL(Data("RIFF\0\0\0\0WEBPVP8 ".utf8))?.hasPrefix("data:image/webp;base64,") == true)
        #expect(AgentReplyAvatars.dataURL(Data("<svg onload=x>".utf8)) == nil)
        #expect(AgentReplyAvatars.dataURL(Data()) == nil)
        #expect(AgentReplyAvatars.dataURL(Self.png + Data(count: AgentReplyAvatars.maximumBytes)) == nil)
    }

    /// The pull request's answer never waits for its author's avatar: it comes without one, still
    /// reading so an open card keeps asking, and a later answer has it once the image is in.
    @Test func theAvatarNeverDelaysTheAnswer() async throws {
        let (gate, open) = AsyncStream<Void>.makeStream()
        let avatars = AgentReplyAvatars(fetch: { _ in
            for await _ in gate { break }
            return Self.png
        })
        let github = FakeGitHub([7: Pull(state: "OPEN", avatar: "https://avatars.githubusercontent.com/u/1?s=48&v=4")])
        let time = FakeTime()
        let calls = AgentChatPullRequestReader.Calls()
        let cache = Self.cache(github, time, calls: calls, avatars: avatars)
        cache.register([Self.url(7)])
        await cache.idle()
        // The image is still loading: the answer is whole, with no avatar, and says it is still
        // reading, so the card asks again rather than keeping the monogram.
        let first = cache.answer(Self.url(7))
        #expect(first.pullRequest?.title == "PR 7")
        #expect(first.pullRequest?.authorAvatar == nil)
        #expect(first.reading)
        let readsBefore = calls.counts.reads
        _ = cache.answer(Self.url(7))
        #expect(calls.counts.reads == readsBefore, "the avatar's wait reads nothing more from GitHub")
        #expect((first.pullRequest?.json.foundationObject as? [String: Any])?["authorAvatar"] == nil)
        open.yield()
        await avatars.loaded("octocat")
        let settled = cache.answer(Self.url(7))
        #expect(settled.reading == false)
        let later = try #require(settled.pullRequest)
        #expect(later.authorAvatar == "data:image/png;base64," + Self.png.base64EncodedString())
        #expect((later.json.foundationObject as? [String: Any])?["authorAvatar"] as? String == later.authorAvatar)
        open.finish()
    }

    /// One load in flight per login, and a failed one is not tried again for ten minutes.
    @Test func anAvatarLoadsOncePerLoginAndWaitsAfterAFailure() async {
        let fetches = OSAllocatedUnfairLock(initialState: 0)
        let time = FakeTime()
        let avatars = AgentReplyAvatars(fetch: { _ in fetches.withLock { $0 += 1 }; return nil },
                                        now: { [time] in time.start + time.elapsed })
        let address = "https://avatars.githubusercontent.com/u/1?s=48&v=4"
        #expect(avatars.image(login: "octocat", address: address) == nil)
        #expect(avatars.image(login: "octocat", address: address) == nil)
        await avatars.loaded("octocat")
        #expect(fetches.withLock { $0 } == 1)
        time.elapsed = .seconds(599)
        _ = avatars.image(login: "octocat", address: address)
        await avatars.loaded("octocat")
        #expect(fetches.withLock { $0 } == 1)
        time.elapsed = .seconds(600)
        _ = avatars.image(login: "octocat", address: address)
        await avatars.loaded("octocat")
        #expect(fetches.withLock { $0 } == 2)
    }
}
