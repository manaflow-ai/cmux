@testable import CmuxNextAgentPane
import Foundation
import Testing

/// A failing check that fails the same way at the base of the branch is not the pull request's own
/// red, and the card says so. The trap this is built around: GitHub's `statusCheckRollup` still
/// lists the checks of a run the concurrency group cancelled for a newer run of the same workflow
/// on the same commit, and those read as failures. Comparing the two lists naively would tell a
/// reader "that red is base's" about a red that is theirs — the expensive direction of wrong.
struct AgentPaneBaseRedsTests {
    /// One CheckRun as GraphQL answers it, with the run it belongs to.
    private static func run(_ name: String, _ conclusion: String, workflow: Int, run: Int,
                            status: String = "COMPLETED") -> [String: Any] {
        ["__typename": "CheckRun", "name": name, "status": status, "conclusion": conclusion,
         "checkSuite": ["workflowRun": ["databaseId": run, "workflow": ["databaseId": workflow, "name": "w\(workflow)"]]]]
    }

    /// A commit status, which belongs to no workflow run and so can never be superseded.
    private static func status(_ context: String, _ state: String) -> [String: Any] {
        ["__typename": "StatusContext", "context": context, "state": state]
    }

    /// The trap, as a fixture: at the base tip, `Verify / scripts` failed in run 100 — which the
    /// concurrency group cancelled — and passed in run 101 of the same workflow. The check is green
    /// on the base, so a pull request failing it owns that red.
    @Test func aCancelledRunNeverExcusesAHeadRed() {
        let base = [
            Self.run("Verify / scripts", "FAILURE", workflow: 1, run: 100),
            Self.run("Verify / ci-status", "CANCELLED", workflow: 1, run: 100),
            Self.run("Verify / scripts", "SUCCESS", workflow: 1, run: 101),
            Self.run("Verify / ci-status", "SUCCESS", workflow: 1, run: 101),
        ]
        #expect(AgentPanePullRequest.failing(base).isEmpty,
                "a run that a newer run of its workflow replaced must not count as a base red")
        let head = [Self.run("Verify / scripts", "FAILURE", workflow: 1, run: 200)]
        let list = AgentPanePullRequest.checkList(head, failingOnBase: AgentPanePullRequest.failing(base))
        #expect(list.map(\.name) == ["Verify / scripts"])
        #expect(list.first?.onBase == false, "the head's red is its own: base's newest run passed")
    }

    /// The case the feature exists for: the base's newest run fails the same check.
    @Test func aCheckRedOnTheBaseTipIsNotThePullRequestsOwn() {
        let base = [
            Self.run("Verify / scripts", "SUCCESS", workflow: 1, run: 100),
            Self.run("Verify / scripts", "FAILURE", workflow: 1, run: 101),
            Self.run("web / lint", "SUCCESS", workflow: 2, run: 300),
        ]
        #expect(AgentPanePullRequest.failing(base) == ["Verify / scripts"])
        let head = [
            Self.run("Verify / scripts", "FAILURE", workflow: 1, run: 200),
            Self.run("web / lint", "FAILURE", workflow: 2, run: 400),
        ]
        let list = AgentPanePullRequest.checkList(head, failingOnBase: AgentPanePullRequest.failing(base))
        let byName = Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0.onBase) })
        #expect(byName["Verify / scripts"] == true)
        #expect(byName["web / lint"] == false, "the base's newest run of that workflow passed it")
    }

    /// A cancelled run that *is* the newest is still no evidence: it never reached a verdict. Only a
    /// check that ran and failed on the base can excuse the same check on a head.
    @Test func aCancelledNewestRunIsNoEvidenceEither() {
        let base = [Self.run("Verify / scripts", "CANCELLED", workflow: 1, run: 101)]
        #expect(AgentPanePullRequest.failing(base).isEmpty)
        let list = AgentPanePullRequest.checkList([Self.run("Verify / scripts", "FAILURE", workflow: 1, run: 200)],
                                                  failingOnBase: AgentPanePullRequest.failing(base))
        #expect(list.first?.onBase == false)
    }

    /// A commit status has no run to be superseded by, so its failure stands as read. A check the
    /// base never ran at all is the pull request's own.
    @Test func statusContextsAndUnknownChecksReadAsThemselves() {
        let base = [Self.status("ci/legacy", "FAILURE"), Self.status("ci/other", "SUCCESS")]
        #expect(AgentPanePullRequest.failing(base) == ["ci/legacy"])
        let head = [Self.status("ci/legacy", "FAILURE"), Self.run("only here", "FAILURE", workflow: 9, run: 1)]
        let list = AgentPanePullRequest.checkList(head, failingOnBase: AgentPanePullRequest.failing(base))
        let byName = Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0.onBase) })
        #expect(byName["ci/legacy"] == true)
        #expect(byName["only here"] == false)
    }

    /// The head's own superseded runs are dropped the same way, so the card does not count a
    /// cancelled run's checks as failures of the head either.
    @Test func theHeadsOwnSupersededRunIsDroppedToo() {
        let head = [
            Self.run("Verify / scripts", "CANCELLED", workflow: 1, run: 200),
            Self.run("Verify / scripts", "SUCCESS", workflow: 1, run: 201),
        ]
        #expect(AgentPanePullRequest.checks(head) == .init(state: "passing", passed: 1, total: 1))
        #expect(AgentPanePullRequest.checkList(head, failingOnBase: []).map(\.state) == ["passed"])
    }

    /// A rollup with no run ids at all (a `gh pr view`, which does not read them) is left alone:
    /// every check counts, exactly as before this comparison existed.
    @Test func aRollupWithoutRunIdsIsUnchanged() {
        let plain: [[String: Any]] = [
            ["__typename": "CheckRun", "name": "a", "status": "COMPLETED", "conclusion": "FAILURE"],
            ["__typename": "CheckRun", "name": "b", "status": "COMPLETED", "conclusion": "SUCCESS"],
        ]
        #expect(AgentPanePullRequest.latestRuns(plain).count == 2)
        #expect(AgentPanePullRequest.checks(plain) == .init(state: "failing", passed: 1, total: 2))
    }

    /// Nothing known about the base means nothing claimed: with no base rollup, no check is marked,
    /// so the single-link `gh pr view` path (which cannot read one) draws the card it always did.
    @Test func noBaseAnswerMarksNothing() throws {
        let view = #"""
            {"url":"https://github.com/o/r/pull/7","number":7,"state":"OPEN","isDraft":false,
             "statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"FAILURE"}]}
            """#
        let pullRequest = try #require(AgentPanePullRequest(ghView: Data(view.utf8)))
        #expect(pullRequest.checkList.map(\.onBase) == [false])
        #expect(!pullRequest.json.compactText.contains(#""onBase":true"#))
        #expect(pullRequest.json.compactText.contains(#""failingOnBase":0"#), "nothing claimed, said plainly")
    }

    /// Read end to end from a batched answer: the base ref's rollup arrives beside the head's, and
    /// the trap's cancelled run does not excuse the head's red.
    @Test func aBatchedAnswerCarriesTheBaseRefsChecks() throws {
        let view = #"""
            {"url":"https://github.com/o/r/pull/7","number":7,"state":"OPEN","isDraft":false,
             "statusCheckRollup":[{"__typename":"CheckRun","name":"Verify / scripts","status":"COMPLETED",
               "conclusion":"FAILURE","checkSuite":{"workflowRun":{"databaseId":200,"workflow":{"databaseId":1,"name":"Verify"}}}},
              {"__typename":"CheckRun","name":"web / lint","status":"COMPLETED","conclusion":"FAILURE",
               "checkSuite":{"workflowRun":{"databaseId":400,"workflow":{"databaseId":2,"name":"web"}}}}],
             "baseStatusCheckRollup":[{"__typename":"CheckRun","name":"Verify / scripts","status":"COMPLETED",
               "conclusion":"FAILURE","checkSuite":{"workflowRun":{"databaseId":100,"workflow":{"databaseId":1,"name":"Verify"}}}},
              {"__typename":"CheckRun","name":"Verify / scripts","status":"COMPLETED","conclusion":"SUCCESS",
               "checkSuite":{"workflowRun":{"databaseId":101,"workflow":{"databaseId":1,"name":"Verify"}}}},
              {"__typename":"CheckRun","name":"web / lint","status":"COMPLETED","conclusion":"FAILURE",
               "checkSuite":{"workflowRun":{"databaseId":301,"workflow":{"databaseId":2,"name":"web"}}}}]}
            """#
        let pullRequest = try #require(AgentPanePullRequest(ghView: Data(view.utf8)))
        let byName = Dictionary(uniqueKeysWithValues: pullRequest.checkList.map { ($0.name, $0.onBase) })
        #expect(byName["Verify / scripts"] == false, "base's newest Verify run passed it")
        #expect(byName["web / lint"] == true)
        #expect(pullRequest.checks.failingOnBase == 1, "one of the two reds is base's")
        #expect(pullRequest.json.compactText.contains(#""onBase":true"#))
    }
}
