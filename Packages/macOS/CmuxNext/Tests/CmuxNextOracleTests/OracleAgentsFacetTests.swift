#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextOracle
import Testing

/// The agents facet: each agent chat tab's session row and each Home view's conversation in the
/// schema's shape, read in the snapshot's main-actor turn; with its host gone it is not-comparable with its task,
/// never an empty pass. Run: `swift test --filter OracleAgentsFacetTests`.
@MainActor
struct OracleAgentsFacetTests {
    static let draftHash = "sha256:" + String(repeating: "a", count: 64)

    @Test func aReadingIsTheSchemasObject() throws {
        var started = OracleAgentsFacet.Session(tab: "tab-1", workspace: "ws-1", session: "s-1")
        started.agent = "claude"
        started.state = .input
        started.turn = 3
        started.pendingApprovals = 1
        var fresh = OracleAgentsFacet.Session(tab: "tab-2", workspace: nil, session: nil)
        fresh.draftSha256 = Self.draftHash
        let reading = OracleAgentsFacet.Reading(sessions: [started, fresh],
                                                home: [OracleAgentsFacet.HomePage(window: "win-1", conversation: "c-1"),
                                                       OracleAgentsFacet.HomePage(tab: "tab-3", conversation: nil)])
        let facet = OracleAgentsFacet { reading }
        #expect(facet.facet == .agents)
        let snapshot = try #require(try OracleFacets([facet]).beginCapture([.agents]).completed)
        let startedRow: OracleValue = ["tab": "tab-1", "workspace": "ws-1", "session": "s-1", "agent": "claude", "state": "input",
                                       "turn": 3, "pendingApprovals": 1, "draftSha256": nil]
        let freshRow: OracleValue = ["tab": "tab-2", "workspace": nil, "session": nil, "agent": nil, "state": "unknown", "turn": 0,
                                     "pendingApprovals": 0, "draftSha256": .string(Self.draftHash)]
        let windowPage: OracleValue = ["window": "win-1", "tab": nil, "conversation": "c-1"]
        let tabPage: OracleValue = ["window": nil, "tab": "tab-3", "conversation": nil]
        let expected: OracleValue = ["sessions": .array([startedRow, freshRow]), "home": .array([windowPage, tabPage])]
        #expect(snapshot["agents"] == expected)
    }

    @Test func aRowTakesTheLanesStateAndCounts() {
        let lane = OracleAgentsFacet.Session.Lane(state: "working", turns: 2, pendingPermissions: 0)
        let row = OracleAgentsFacet.Session(tab: "t", workspace: nil, session: "s", agent: "codex", lane: lane, draftSha256: nil)
        #expect(row.state == .working && row.turn == 2 && row.pendingApprovals == 0 && row.agent == "codex")
        let odd = OracleAgentsFacet.Session.Lane(state: "napping", turns: -1, pendingPermissions: -3)
        let unknown = OracleAgentsFacet.Session(tab: "t", workspace: nil, session: "s", agent: nil, lane: odd, draftSha256: nil)
        #expect(unknown.state == .unknown && unknown.turn == 0 && unknown.pendingApprovals == 0)
        let none = OracleAgentsFacet.Session(tab: "t", workspace: nil, session: nil, agent: nil, lane: nil, draftSha256: nil)
        #expect(none.state == .unknown && none.turn == 0)
    }

    @Test func noHostIsNotComparable() throws {
        let snapshot = try #require(try OracleFacets([OracleAgentsFacet { nil }]).beginCapture([.agents]).completed)
        #expect(snapshot["agents"]?["status"] == "not-comparable")
        #expect(snapshot["agents"]?["task"] == "p15-oracle-043")
    }
}
#endif
