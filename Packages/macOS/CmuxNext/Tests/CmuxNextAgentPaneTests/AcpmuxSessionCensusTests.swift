@testable import CmuxNextAgentPane
import Testing

/// The quit dialog counts the local agents that keep running after the app
/// quits, and the ones in a turn now, from `_acpmux/sessions`.
struct AcpmuxSessionCensusTests {
    static func session(_ id: String, _ status: String, name: String? = nil, title: String? = nil,
                        turnStartedAt: Int? = nil, tags: [String: String] = [:]) -> [String: Any] {
        var summary: [String: Any] = ["sessionId": id, "status": status, "tags": tags]
        if let name { summary["name"] = name }
        if let title { summary["title"] = title }
        if let turnStartedAt { summary["turn"] = ["startedAt": turnStartedAt] }
        return summary
    }

    @Test func countsLiveAgentsAndAgentsInATurn() {
        let result: [String: Any] = ["sessions": [
            Self.session("a", "ready", name: "idle-ready"),
            Self.session("b", "running", name: "fix-tests", title: "Fix the flaky tests", turnStartedAt: 20),
            Self.session("c", "waiting", name: "deploy", turnStartedAt: 10),
            Self.session("d", "idle", name: "parked"),
            Self.session("e", "closed", name: "done"),
            Self.session("f", "disconnected", name: "crashed"),
        ]]
        let census = AcpmuxSessionCensus.parse(result)
        #expect(census.live == 3)
        #expect(census.inTurn == 2)
        // Oldest turn first; the title wins over the name.
        #expect(census.inTurnNames == ["deploy", "Fix the flaky tests"])
    }

    @Test func aSessionWithoutANameUsesItsId() {
        let census = AcpmuxSessionCensus.parse(["sessions": [Self.session("01a1071f", "running", turnStartedAt: 1)]])
        #expect(census.inTurnNames == ["01a1071f"])
    }

    /// The Home Chief is never counted; its turn shows as one flag.
    @Test func theChiefIsExcludedAndFlaggedWhenInATurn() {
        let chief = [AcpmuxSessionCensus.chiefTagKey: "home-chief"]
        let busy = AcpmuxSessionCensus.parse(["sessions": [
            Self.session("chief", "running", name: "Chief", turnStartedAt: 1, tags: chief),
            Self.session("b", "ready", name: "helper"),
        ]])
        #expect(busy == AcpmuxSessionCensus(live: 1, inTurn: 0, inTurnNames: [], chiefInTurn: true))
        let idle = AcpmuxSessionCensus.parse(["sessions": [Self.session("chief", "ready", name: "Chief", tags: chief)]])
        #expect(idle == AcpmuxSessionCensus())
    }

    @Test func noSessionsIsZero() {
        #expect(AcpmuxSessionCensus.parse(["sessions": [] as [Any]]) == AcpmuxSessionCensus())
        #expect(AcpmuxSessionCensus.parse([:]) == AcpmuxSessionCensus())
    }
}
