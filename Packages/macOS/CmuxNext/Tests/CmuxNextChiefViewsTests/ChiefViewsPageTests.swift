import CmuxNextAgentActivity
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextChiefViews

/// The Chief view gallery's app side (webviews/src/pages/chief-views): lanes become rows in the
/// page's four states, the CI dashboard's data.json is trimmed to the Fleet reply, GitHub's search
/// becomes the Landing reply, and the ops that act (set the dashboard, reveal an agent, open a PR)
/// answer only a person's click.
@MainActor
@Suite
struct ChiefViewsPageTests {
    private static let page = PageCallContext(page: "cmux.chief-views")
    private static let click = PageCallContext(page: "cmux.chief-views", userGesture: true, gestureEvent: 1)

    @Test func lanesMapToTheFourStatesAndKeepTheirSummaryFields() throws {
        let summary: [String: Any] = [
            "sessionId": "s1", "name": "huge-blue/chiefviews", "peer": "huge-blue", "cwd": "/w/chiefviews/cmux",
            "updatedMs": NSNumber(value: 1_792_535_000_000), "createdMs": NSNumber(value: 1_792_500_000_000),
            "harness": "claude",
            "lane": ["state": "lost", "since": NSNumber(value: 1_792_534_000_000), "step": "Writing the Fleet view"],
        ]
        let lane = try #require(AgentActivityLane.of(summary: summary))
        #expect(lane.cwd == "/w/chiefviews/cmux")
        #expect(lane.updatedAt == Date(timeIntervalSince1970: 1_792_535_000))
        #expect(lane.createdAt == Date(timeIntervalSince1970: 1_792_500_000))

        let row = ChiefViewsAgent(lane: lane)
        #expect(row.state == .failed)
        #expect(row.machine == "huge-blue")
        #expect(row.task == "Writing the Fleet view")
        let states = ["working", "input", "idle", "failed"].compactMap { state in
            AgentActivityLane.of(summary: ["sessionId": "x", "lane": ["state": state]]).map { ChiefViewsAgent(lane: $0).state }
        }
        #expect(states == [.working, .waiting, .idle, .failed])
        // Output alone (a later updatedAt) is a new value, so the gallery's last-output time follows it.
        var later = summary
        later["updatedMs"] = NSNumber(value: 1_792_536_000_000)
        let moved = try #require(AgentActivityLane.of(summary: later))
        #expect(moved != lane && moved.updatedAt == Date(timeIntervalSince1970: 1_792_536_000))
        // A summary without the new fields still reads, as before.
        let bare = try #require(AgentActivityLane.of(summary: ["sessionId": "y", "lane": ["state": "idle"]]))
        #expect(bare.cwd == nil && bare.updatedAt == nil && bare.createdAt == nil)
        #expect(ChiefViewsAgent(lane: bare).machine == ChiefViewsAgent.localMachine)
    }

    @Test func agentsReplyCarriesEveryFieldThePageReads() {
        var row = ChiefViewsAgent(lane: AgentActivityLane(id: "s", name: "n", title: "T", peer: nil, parent: "chief",
                                                         state: .input, since: Date(timeIntervalSince1970: 2), error: nil))
        row.branch = "feat-x"
        let agent = ChiefViewsPageProvider.reply([row])["agents"]?.arrayValue?.first
        #expect(agent?["state"] == "waiting")
        #expect(agent?["kind"] == "chat")
        #expect(agent?["machine"] == "local")
        #expect(agent?["since"] == .number(2000))
        #expect(agent?["branch"] == "feat-x")
        #expect(agent?["parent"] == "chief")
        #expect(agent?["folder"] == .null)
    }

    @Test func fleetTrimsTheDashboard() throws {
        let data = Data("""
        {"updated":"2026-10-20T22:40:42Z","history":[1,2,3],
         "minis":[{"host":"cmux7s-mac-mini","error":null,"load":[12.5,11,15],"ncpu":14,"cpu_pct":37,"mem_free_pct":72},
                  {"host":"aws-m4pro-9","error":"console locked","load":null,"ncpu":14}],
         "runners":[{"host":"cmux7s-mac-mini","status":"online","busy":true},{"host":"cmux7s-mac-mini","status":"online","busy":false},
                    {"host":"cmux7s-mac-mini","status":"offline","busy":true}],
         "queued":[{"job":"a"},{"job":"b"}],
         "recent_prs":[{"pr":22640,"title":"cmux-next · b844","branch":"fix/x","status":"running"},{"pr":null}]}
        """.utf8)
        let reply = try #require(ChiefViewsFeeds.fleetReply(data))
        #expect(reply["updated"] == "2026-10-20T22:40:42Z")
        #expect(reply["queued"] == 2)
        let machines = try #require(reply["machines"]?.arrayValue)
        #expect(machines.count == 2)
        #expect(machines[0]["load"] == .number(12.5))
        #expect(machines[0]["runnersBusy"] == 1)
        #expect(machines[0]["runnersOnline"] == 2)
        #expect(machines[1]["error"] == "console locked")
        #expect(machines[1]["load"] == .null)
        #expect(reply["prs"]?.arrayValue?.count == 1)
        #expect(reply.objectValue.map { Set($0.keys) } == ["updated", "machines", "queued", "prs"])
        #expect(ChiefViewsFeeds.fleetReply(Data("{\"other\":1}".utf8)) == nil)
    }

    @Test func dashboardAddressesAreHTTPSOrPrivateHTTP() {
        #expect(ChiefViewsFeeds.validFleetURL(" https://ci.example.test:8444/ ")?.host == "ci.example.test")
        #expect(ChiefViewsFeeds.validFleetURL("http://ci.example.test/") == nil)
        #expect(ChiefViewsFeeds.validFleetURL("http://localhost:8444/") != nil)
        #expect(ChiefViewsFeeds.validFleetURL("http://mini.tail0.ts.net:8444/") != nil)
        #expect(ChiefViewsFeeds.validFleetURL("file:///etc/passwd") == nil)
        #expect(ChiefViewsFeeds.validFleetURL("https://user:pw@ci.example.test/") == nil)
        #expect(ChiefViewsFeeds.validFleetURL("not a url") == nil)
        let base = URL(string: "https://ci.example.test:8444/")!
        #expect(ChiefViewsFeeds.fleetDataURL(base).absoluteString == "https://ci.example.test:8444/data.json")
        let named = URL(string: "https://ci.example.test/data.json")!
        #expect(ChiefViewsFeeds.fleetDataURL(named) == named)
    }

    @Test func landingReadsGitHubSearch() throws {
        let data = Data("""
        {"items":[{"number":22618,"title":"New Tab: dots","html_url":"https://github.com/manaflow-ai/cmux/pull/22618",
                   "user":{"login":"teamleaderleo"},"labels":[{"name":"ready-to-land"}],"draft":false,
                   "created_at":"2026-10-20T10:00:00Z","pull_request":{"merged_at":null}},
                  {"number":1,"title":"elsewhere","html_url":"https://evil.example/pull/1"}]}
        """.utf8)
        let prs = try #require(ChiefViewsFeeds.landingPRs(data))
        #expect(prs.count == 1)
        #expect(prs[0]["labels"] == ["ready-to-land"])
        #expect(prs[0]["author"] == "teamleaderleo")
        #expect(prs[0]["mergedAt"] == .null)
        #expect(ChiefViewsFeeds.landingPRs(Data("{\"message\":\"rate limited\"}".utf8)) == nil)

        let urls = try #require(ChiefViewsFeeds.landingSearchURLs(mergedSince: "2026-10-19"))
        #expect(urls.open.absoluteString.contains("is:open") || urls.open.absoluteString.contains("is%3Aopen"))
        #expect(urls.merged.query?.contains("2026-10-19") == true)
        #expect(ChiefViewsFeeds.searchDay(Date(timeIntervalSince1970: 1_792_535_000)) == "2026-10-19")
        #expect(ChiefViewsFeeds.validPullRequestURL("https://github.com/manaflow-ai/cmux/pull/1") != nil)
        #expect(ChiefViewsFeeds.validPullRequestURL("https://github.com/other/repo/pull/1") == nil)
        #expect(ChiefViewsFeeds.validPullRequestURL("http://github.com/manaflow-ai/cmux/pull/1") == nil)
        #expect(ChiefViewsFeeds.validPullRequestURL("https://github.com/manaflow-ai/cmux/../../other/repo") == nil)
    }

    @Test func actingOpsNeedAClickAndFleetSaysWhenUnset() async throws {
        let defaults = try #require(UserDefaults(suiteName: "ChiefViewsPageTests.\(UUID().uuidString)"))
        let seen = Recorder()
        let provider = ChiefViewsPageProvider(host: .init(
            agents: { [] },
            fetch: { _ in Data(#"{"minis":[]}"#.utf8) },
            defaults: defaults, environment: [:], now: { Date() },
            openAgent: { kind, id in seen.opened.append("\(kind.rawValue):\(id)") },
            openURL: { seen.links.append($0) }))

        do {
            _ = try await provider.call(ChiefViewsPageProvider.fleetOp, params: [:], context: Self.page)
            Issue.record("fleet answered without a dashboard")
        } catch let error as PageError {
            #expect(error.code == ChiefViewsPageProvider.fleetUnavailable)
            #expect(error.details?["configured"] == false)
        }

        for op in [ChiefViewsPageProvider.setFleetURLOp, ChiefViewsPageProvider.openOp, ChiefViewsPageProvider.openURLOp] {
            await #expect(throws: PageError.self) {
                _ = try await provider.call(op, params: ["url": "https://ci.example.test/", "kind": "chat", "id": "s"], context: Self.page)
            }
        }
        #expect(defaults.string(forKey: ChiefViewsPageProvider.fleetURLKey) == nil)
        #expect(seen.opened.isEmpty && seen.links.isEmpty)

        await #expect(throws: PageError.self) {
            _ = try await provider.call(ChiefViewsPageProvider.setFleetURLOp, params: ["url": "file:///etc"], context: Self.click)
        }
        _ = try await provider.call(ChiefViewsPageProvider.setFleetURLOp, params: ["url": "https://ci.example.test/"], context: Self.click)
        let fleet = try await provider.call(ChiefViewsPageProvider.fleetOp, params: [:], context: Self.page)
        #expect(fleet["machines"] == [])

        _ = try await provider.call(ChiefViewsPageProvider.openOp, params: ["kind": "terminal", "id": "tab_1"], context: Self.click)
        _ = try await provider.call(ChiefViewsPageProvider.openURLOp,
                                    params: ["url": "https://github.com/manaflow-ai/cmux/pull/7"], context: Self.click)
        #expect(seen.opened == ["terminal:tab_1"])
        #expect(seen.links.map(\.absoluteString) == ["https://github.com/manaflow-ai/cmux/pull/7"])
    }

    @Test func landingAnswersFromItsReadForNinetySeconds() async throws {
        let defaults = try #require(UserDefaults(suiteName: "ChiefViewsPageTests.\(UUID().uuidString)"))
        let counter = Counter()
        let clock = Recorder()
        let provider = ChiefViewsPageProvider(host: .init(
            agents: { [] },
            fetch: { _ in await counter.bump(); return Data(#"{"items":[]}"#.utf8) },
            defaults: defaults, environment: [:], now: { clock.now },
            openAgent: { _, _ in }, openURL: { _ in }))
        _ = try await provider.call(ChiefViewsPageProvider.landingOp, params: [:], context: Self.page)
        _ = try await provider.call(ChiefViewsPageProvider.landingOp, params: [:], context: Self.page)
        #expect(await counter.value == 2) // one open search and one merged search
        clock.now = clock.now.addingTimeInterval(ChiefViewsPageProvider.landingLifetime + 1)
        let reply = try await provider.call(ChiefViewsPageProvider.landingOp, params: [:], context: Self.page)
        #expect(await counter.value == 4)
        #expect(reply["repo"] == "manaflow-ai/cmux")
        #expect(reply["base"] == "feat-cmux-next")
    }

    /// What the provider's host was asked to do, read back on the main actor.
    @MainActor private final class Recorder {
        var opened: [String] = []
        var links: [URL] = []
        var now = Date(timeIntervalSince1970: 1_792_535_000)
    }

    private actor Counter {
        var value = 0
        func bump() { value += 1 }
    }
}
