import AppKit
@testable import CmuxNextAgentLanes
@testable import CmuxNextAgentPane
import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-19, Claude desktop's session sidebar: hovering a row's pull request badge lists the
/// pull requests its sessions opened, newest first: title, a state pill (Conflict, Checks failed,
/// Checks passing, Draft, Merged, Closed), `owner/repo #N` and `+adds −dels`; a click opens one.
/// Live state comes from one batched GraphQL read per refresh, never one call per pull request.
@MainActor @Suite(.serialized) struct SidebarPullRequestCardTests {
    private static func pr(_ number: Int, state: String = "open", mergeable: String = "mergeable", checks: String = "passing",
                           createdAt: String = "", repo: String = "o/r") -> AgentPanePullRequest {
        AgentPanePullRequest(url: "https://github.com/\(repo)/pull/\(number)", number: number, title: "PR \(number)", state: state,
                             mergeable: mergeable, checks: .init(state: checks, passed: 1, total: 1), createdAt: createdAt,
                             additions: number * 10, deletions: number)
    }

    private static func item(_ number: Int, _ state: SidebarPullRequestItem.State, createdAt: String = "") -> SidebarPullRequestItem {
        SidebarPullRequestItem(url: "https://github.com/o/r/pull/\(number)", repository: "o/r", number: number, title: "PR \(number)",
                               state: state, additions: number, deletions: 1, createdAt: createdAt)
    }

    @Test func eachPullRequestGetsItsPill() {
        #expect(SidebarSessionTreeFeed.item(Self.pr(1)).state == .passing)
        #expect(SidebarSessionTreeFeed.item(Self.pr(1, checks: "pending")).state == .passing)
        #expect(SidebarSessionTreeFeed.item(Self.pr(1, checks: "failing")).state == .failing)
        // A conflict says so before its checks.
        #expect(SidebarSessionTreeFeed.item(Self.pr(1, mergeable: "conflicting", checks: "failing")).state == .conflict)
        #expect(SidebarSessionTreeFeed.item(Self.pr(1, state: "draft")).state == .draft)
        #expect(SidebarSessionTreeFeed.item(Self.pr(1, state: "merged")).state == .merged)
        #expect(SidebarSessionTreeFeed.item(Self.pr(1, state: "closed")).state == .closed)
        let line = SidebarSessionTreeFeed.item(Self.pr(4, repo: "manaflow-ai/cmux"))
        #expect(line.repository == "manaflow-ai/cmux")
        #expect(line.title == "PR 4")
        #expect((line.additions, line.deletions) == (40, 4))
    }

    @Test func theBadgeColorsByTheWorstAndListsNewestFirst() throws {
        let badge = try #require(SidebarPullRequestBadge.combining(items: [
            Self.item(1, .merged, createdAt: "2026-10-01T00:00:00Z"),
            Self.item(2, .conflict, createdAt: "2026-10-03T00:00:00Z"),
            Self.item(3, .failing, createdAt: "2026-10-02T00:00:00Z"),
            Self.item(4, .closed, createdAt: "2026-10-04T00:00:00Z"),
        ]))
        // Closed ones list in the card but leave the count and color.
        #expect(badge.count == 3)
        #expect(badge.status == .failing)
        #expect(badge.items.map(\.number) == [4, 2, 3, 1])
        #expect(SidebarPullRequestBadge.combining(items: [Self.item(1, .merged), Self.item(2, .merged)])?.status == .merged)
        #expect(SidebarPullRequestBadge.combining(items: [Self.item(1, .conflict), Self.item(2, .passing)])?.status == .attention)
        #expect(SidebarPullRequestBadge.combining(items: [Self.item(1, .closed)]) == nil)
        #expect(SidebarPullRequestBadge.combining(items: []) == nil)
    }

    @Test func aRepositoryComesFromItsURL() {
        #expect(SidebarPullRequestItem.repository(of: "https://github.com/manaflow-ai/cmux/pull/21823") == "manaflow-ai/cmux")
        #expect(SidebarPullRequestItem.repository(of: "https://github.com/o/r/issues/3") == "")
        #expect(SidebarPullRequestItem.repository(of: "nonsense") == "")
    }

    @Test func oneGraphQLReadAsksForEveryPullRequest() {
        typealias Target = AgentChatPullRequestReader.Target
        let targets = ["https://github.com/o/r/pull/7", "https://github.com/manaflow-ai/cmux/pull/21823"].compactMap(Target.init(url:))
        #expect(targets.map(\.number) == [7, 21823])
        // Only plain github.com pull request URLs: nothing reaches the query unchecked.
        for bad in ["https://github.com/o\"){x}/r/pull/1", "https://evil.example/o/r/pull/1", "https://github.com/o/r/pull/1/files",
                    "https://github.com/o/r/pull/01", "http://github.com/o/r/pull/1", "https://github.com/o/r/issues/1"] {
            #expect(Target(url: bad) == nil, "\(bad)")
        }
        let query = AgentChatPullRequestReader.query(targets)
        #expect(query.contains("p0: repository(owner: \"o\", name: \"r\") { pullRequest(number: 7) { ...f } }"))
        #expect(query.contains("p1: repository(owner: \"manaflow-ai\", name: \"cmux\") { pullRequest(number: 21823) { ...f } }"))
        #expect(query.contains("additions deletions"))
        #expect(query.filter { $0 == "{" }.count == query.filter { $0 == "}" }.count)
    }

    @Test func aGraphQLAnswerReadsAsGhPrViewDoes() throws {
        let targets = ["https://github.com/o/r/pull/7", "https://github.com/o/r/pull/8", "https://github.com/o/r/pull/9"]
            .compactMap(AgentChatPullRequestReader.Target.init(url:))
        let answer = """
            {"data":{
             "p0":{"pullRequest":{"url":"https://github.com/o/r/pull/7","number":7,"title":"Stage hunks","state":"OPEN","isDraft":false,
               "reviewDecision":null,"mergeable":"CONFLICTING","createdAt":"2026-10-01T09:30:00Z","mergedAt":null,"additions":120,"deletions":8,
               "commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
                 {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.com/o/r/actions/runs/1"},
                 {"__typename":"StatusContext","context":"ci/lint","state":"SUCCESS","targetUrl":"https://ci.example/2"}]}}}}]}}},
             "p1":{"pullRequest":{"url":"https://github.com/o/r/pull/8","number":8,"title":"Docs","state":"MERGED","isDraft":false,
               "mergeable":"UNKNOWN","createdAt":"2026-10-02T00:00:00Z","mergedAt":"2026-10-03T00:00:00Z","additions":3,"deletions":1,
               "commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}},
             "p2":null},
             "errors":[{"type":"NOT_FOUND","path":["p2"]}]}
            """
        let read = AgentChatPullRequestReader.pullRequests(fromGraphQL: Data(answer.utf8), targets)
        #expect(read.count == 3)
        // GitHub answered null for pull/9: it has none, so its old answer clears.
        #expect(read.keys.contains("https://github.com/o/r/pull/9"))
        #expect(read["https://github.com/o/r/pull/9"] == .some(nil))
        let seven = try #require(read["https://github.com/o/r/pull/7"] ?? nil)
        #expect(seven.state == "open")
        #expect(seven.mergeable == "conflicting")
        #expect(seven.checks == .init(state: "failing", passed: 1, total: 2))
        #expect((seven.additions, seven.deletions) == (120, 8))
        #expect(SidebarSessionTreeFeed.item(seven).state == .conflict)
        let eight = try #require(read["https://github.com/o/r/pull/8"] ?? nil)
        #expect(eight.state == "merged")
        #expect(eight.checks.state == "none")
    }

    /// A read that failed (offline, rate limited, bad auth: no `data`) answers for no URL, so the
    /// store keeps each one's last answer instead of dropping every badge.
    @Test func aFailedGraphQLReadAnswersForNoURL() {
        let targets = ["https://github.com/o/r/pull/7"].compactMap(AgentChatPullRequestReader.Target.init(url:))
        for failure in ["", "not json", #"{"message":"API rate limit exceeded"}"#, #"{"data":null,"errors":[{"message":"Bad credentials"}]}"#] {
            #expect(AgentChatPullRequestReader.pullRequests(fromGraphQL: Data(failure.utf8), targets).isEmpty, "\(failure)")
        }
    }

    @Test func pullRequestsOpenedTheSameMomentListByNumber() throws {
        let badge = try #require(SidebarPullRequestBadge.combining(items: [Self.item(9, .passing), Self.item(10, .passing), Self.item(2, .passing)]))
        #expect(badge.items.map(\.number) == [10, 9, 2])
    }

    @Test func theCardShowsEightLinesThenScrollsAndOpensAClick() {
        let card = SidebarPullRequestCardView(frame: NSRect(x: 0, y: 0, width: SidebarPullRequestCardView.width, height: 400))
        var opened: [Int] = []
        card.onOpen = { opened.append($0.number) }
        card.configure((1...3).map { Self.item($0, .passing) })
        let row = SidebarPullRequestCardRow.height, pad = 2 * Metrics.space1
        #expect(card.preferredHeight == 3 * row + pad)
        card.configure((1...12).map { Self.item($0, .merged) })
        #expect(card.shownCount == 12)
        #expect(card.preferredHeight == CGFloat(SidebarPullRequestCardView.visibleRows) * row + pad)
        card.configure([Self.item(5, .failing)])
        #expect(card.shownCount == 1)
        #expect(card.reportedLines == ["PR 5 \(CmuxNextSidebar.Strings.pullRequestState(.failing)) o/r #5 +5 \u{2212}1"])
        _ = card.rows[0].accessibilityPerformPress()
        #expect(opened == [5])
        #expect(card.rows[0].accessibilityLabel()?.contains("o/r #5") == true)
    }

    @Test func everyStateHasItsOwnPillText() {
        let texts = SidebarPullRequestItem.State.allCases.map(CmuxNextSidebar.Strings.pullRequestState)
        #expect(Set(texts).count == SidebarPullRequestItem.State.allCases.count)
        #expect(CmuxNextSidebar.Strings.pullRequestState(.conflict) == "Conflict")
        #expect(CmuxNextSidebar.Strings.pullRequestState(.passing) == "Checks passing")
    }

    /// The gallery's fixtures (`SidebarPullRequestCard.gallery.ts`) are `{items: [SidebarPullRequestItem]}`.
    @Test func aGalleryFixtureDecodesIntoTheCard() throws {
        let fixture = """
            {"items":[{"url":"https://github.com/manaflow-ai/cmux/pull/21851","repository":"manaflow-ai/cmux","number":21851,
              "title":"Sidebar pull request hover card","state":"failing","additions":688,"deletions":41,"createdAt":"2026-10-19T09:00:00Z"},
             {"url":"https://github.com/manaflow-ai/cmux/pull/21814","repository":"manaflow-ai/cmux","number":21814,
              "title":"cmux NEXT sidebar: session tree","state":"merged","additions":1204,"deletions":88,"createdAt":"2026-10-14T09:00:00Z"}]}
            """
        struct Fixture: Decodable { var items: [SidebarPullRequestItem] }
        let items = try JSONDecoder().decode(Fixture.self, from: Data(fixture.utf8)).items
        #expect(items.map(\.state) == [.failing, .merged])
        let card = SidebarPullRequestCardView(frame: NSRect(x: 0, y: 0, width: SidebarPullRequestCardView.width, height: 200))
        card.configure(items)
        #expect(card.reportedLines.first?.hasPrefix("Sidebar pull request hover card") == true)
        #expect(SidebarPullRequestBadge.combining(items: items)?.status == .failing)
    }

    @Test func theCardIsADebugSettingOnByDefault() {
        #expect(SidebarTunables.pullRequestCard.descriptor.key == "sidebar.pullRequestCard")
        #expect(SidebarTunables.all.contains { $0.key == "sidebar.pullRequestCard" })
    }
}
