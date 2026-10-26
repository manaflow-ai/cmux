#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextAgentActivity
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextOracle
import Foundation
import Observation
import os
import Testing

/// The app's agents facet (p15-oracle-043): an agent chat tab's row takes its session and harness from the store
/// record and its state, turn count and open permission requests from acpmux's lane (`turnCount`,
/// `pendingPermissions` of the session summary); a new chat's kept composer text goes in only as its sha256, and
/// a change of that text is heard by a reader. Run: `swift test --filter AppOracleAgentsFacetTests`.
@MainActor @Suite(.serialized) struct AppOracleAgentsFacetTests {
    /// One acpmux session summary with its lane and counts, as the watch sends it.
    private func summary(_ state: String, turnCount: Any? = nil, pendingPermissions: Any? = nil) -> [String: Any] {
        var summary: [String: Any] = ["sessionId": "s-1", "name": "s-1", "harness": "codex",
                                      "lane": ["state": state, "since": 1_760_000_000_000]]
        if let turnCount { summary["turnCount"] = turnCount }
        if let pendingPermissions { summary["pendingPermissions"] = pendingPermissions }
        return summary
    }

    @Test func aLaneReadsTheSummarysTurnCountAndOpenPermissions() throws {
        let asking = try #require(AgentActivityLane.of(summary: summary("input", turnCount: 4, pendingPermissions: 2)))
        #expect(asking.turnCount == 4)
        #expect(asking.pendingPermissions == 2)
        let bare = try #require(AgentActivityLane.of(summary: summary("idle")))
        #expect(bare.turnCount == 0 && bare.pendingPermissions == 0, "an acpmux without the counts reads 0")
        let odd = try #require(AgentActivityLane.of(summary: summary("idle", turnCount: -1, pendingPermissions: "2")))
        #expect(odd.turnCount == 0 && odd.pendingPermissions == 0, "a negative or non-number count reads 0")
    }

    @Test func aSessionRowTakesTheLaneAndHashesTheDraft() throws {
        let lane = try #require(AgentActivityLane.of(summary: summary("input", turnCount: 4, pendingPermissions: 2)))
        let row = AppServices.oracleSession(tab: "tab-1", workspace: "ws-1", record: AgentSessionRef(host: "install:a", session: "s-1"),
                                            lane: lane, draft: "hello")
        #expect(row.session == "s-1")
        #expect(row.agent == "codex", "with no harness on the record, the lane's")
        #expect(row.state == .input)
        #expect(row.turn == 4)
        #expect(row.pendingApprovals == 2)
        #expect(row.draftSha256 == "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        #expect(!String(describing: row.value).contains("hello"), "the draft text never goes in")
    }

    @Test func aNewChatWithNoLaneIsUnknown() {
        let record = AgentSessionRef(host: "install:a", session: nil, harness: "claude")
        let row = AppServices.oracleSession(tab: "tab-2", workspace: nil, record: record, lane: nil, draft: nil)
        #expect(row.session == nil)
        #expect(row.agent == "claude")
        #expect(row.state == .unknown)
        #expect(row.turn == 0 && row.pendingApprovals == 0)
        #expect(row.draftSha256 == nil)
    }

    @Test func aDraftChangeIsHeard() {
        let drafts = AgentUnsentDrafts(file: nil)
        let heard = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = drafts.draft(for: "tab-1") } onChange: { heard.withLock { $0 = true } }
        drafts.set("compare the two retry policies", for: "tab-1")
        #expect(heard.withLock { $0 })
        #expect(drafts.draft(for: "tab-1") == "compare the two retry policies")
    }

    @Test func anAppWithNoAgentTabsListsNone() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let facets = services.makeOracleFacets()
        #expect(facets.provided.contains(.agents))
        let snapshot = try #require(try facets.beginCapture([.agents]).completed)
        #expect(snapshot["agents"] == ["sessions": [], "home": []])
    }
}
#endif
