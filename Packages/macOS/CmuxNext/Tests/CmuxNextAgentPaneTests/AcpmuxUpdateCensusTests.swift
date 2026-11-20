import CmuxNextAgentPane
import Testing

struct AcpmuxUpdateCensusTests {
    @Test func missingActivityCannotAuthorizeAnUpdate() {
        let rows: [[String: Any]] = [
            ["status": "ready"],
            ["status": "ready", "hasDraft": false],
            ["status": "ready", "workingBelow": false],
        ]
        for row in rows {
            let census = AcpmuxSessionCensus.parse(["sessions": [row]])
            #expect(census.live == 1)
            #expect(!census.updateActivityKnown)
        }
        #expect(!AcpmuxSessionCensus.parse([:]).updateActivityKnown)
        #expect(!AcpmuxSessionCensus(live: 1).updateActivityKnown)
    }

    @Test func explicitIdleAndEmptyAnswersAreKnown() {
        let census = AcpmuxSessionCensus.parse(["sessions": [
            ["status": "ready", "hasDraft": false, "workingBelow": false],
        ]])
        #expect(census.updateActivityKnown)
        #expect(census.drafts == 0 && census.workingBelow == 0)
        #expect(AcpmuxSessionCensus.parse(["sessions": [[String: Any]]()]).updateActivityKnown)
    }

    @Test func draftsAndBackgroundWorkIncludeChiefSessions() {
        let census = AcpmuxSessionCensus.parse(["sessions": [
            ["name": "optchat-home", "status": "ready", "hasDraft": true, "workingBelow": true],
        ]])
        #expect(census.updateActivityKnown)
        #expect(census.drafts == 1 && census.workingBelow == 1)
        #expect(census.live == 0)
    }
}
