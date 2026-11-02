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
        #expect(AgentPanePullRequest.failing(base)
            == [AgentPanePullRequest.identity(Self.run("Verify / scripts", "FAILURE", workflow: 1, run: 101))])
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
        #expect(AgentPanePullRequest.failing(base) == [AgentPanePullRequest.identity(Self.status("ci/legacy", "FAILURE"))])
        let head = [Self.status("ci/legacy", "FAILURE"), Self.run("only here", "FAILURE", workflow: 9, run: 1)]
        let list = AgentPanePullRequest.checkList(head, failingOnBase: AgentPanePullRequest.failing(base))
        let byName = Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0.onBase) })
        #expect(byName["ci/legacy"] == true)
        #expect(byName["only here"] == false)
    }

    /// ``AgentPanePullRequest/checks(_:failingOnBase:)`` itself counts what it is given whole, so
    /// the merge gate (which reads a raw rollup) stays strict; the card's counts come through
    /// ``AgentPanePullRequest/counted(_:)``, which keeps each check's newest run.
    @Test func checksCountsWholeAndCountedKeepsTheNewestRun() {
        let head = [
            Self.run("mux bun test", "FAILURE", workflow: 1, run: 200),
            Self.run("mux bun test", "SUCCESS", workflow: 1, run: 201),
        ]
        #expect(AgentPanePullRequest.checks(head) == .init(state: "failing", passed: 1, total: 2))
        let counted = AgentPanePullRequest.counted(head)
        #expect(AgentPanePullRequest.checks(counted) == .init(state: "passing", passed: 1, total: 1))
        #expect(AgentPanePullRequest.checkList(counted, failingOnBase: []).map(\.state) == ["passed"])
    }

    /// The bug that made this: label and edit events re-ran the same workflows on one head, the
    /// concurrency groups cancelled the older runs, and the Changes row read "19 failing" for a
    /// pull request with two real reds. Cancelled duplicates, then one later success per check,
    /// plus one real failure, count as 1 failing.
    @Test func cancelledDuplicatesAndSupersededRunsAreNotCounted() throws {
        var rollup: [[String: Any]] = []
        for name in ["Verify / scripts", "web / lint", "macOS compile"] {
            rollup.append(Self.run(name, "CANCELLED", workflow: 1, run: 100))
            rollup.append(Self.run(name, "CANCELLED", workflow: 1, run: 101))
            rollup.append(Self.run(name, "SUCCESS", workflow: 1, run: 102))
        }
        rollup.append(Self.run("Swift tests", "CANCELLED", workflow: 2, run: 300))
        rollup.append(Self.run("Swift tests", "FAILURE", workflow: 2, run: 301))
        rollup.append(Self.run("docs", "SKIPPED", workflow: 3, run: 400))
        #expect(AgentPanePullRequest.checks(rollup).total == 12, "counted whole, the trap")

        let data = try JSONSerialization.data(withJSONObject: [
            "url": "https://github.com/o/r/pull/7", "number": 7, "state": "OPEN", "statusCheckRollup": rollup,
        ] as [String: Any])
        let pullRequest = try #require(AgentPanePullRequest(ghView: data))
        #expect(pullRequest.checks == .init(state: "failing", passed: 3, total: 4))
        #expect(pullRequest.checkList.filter { $0.state == "failed" }.map(\.name) == ["Swift tests"],
                "1 failing, as Session Info's Changes row counts it")
    }

    /// A cancelled re-run never hides the verdict of the run before it, and a check a newer run of
    /// its workflow did not run again keeps its older verdict.
    @Test func aCancelledReRunKeepsThePreviousVerdict() {
        let rollup = [
            Self.run("Swift tests", "FAILURE", workflow: 2, run: 300),
            Self.run("Swift tests", "CANCELLED", workflow: 2, run: 301),
            Self.run("lint", "SUCCESS", workflow: 2, run: 300),
        ]
        let list = AgentPanePullRequest.checkList(AgentPanePullRequest.counted(rollup))
        #expect(list.map(\.name) == ["Swift tests", "lint"])
        #expect(list.map(\.state) == ["failed", "passed"])
    }

    /// A `gh pr view` answer carries no run ids: there gh's `workflowName` and `startedAt` say
    /// which run of a check is newest.
    @Test func aGhViewAnswerUsesWorkflowNameAndStartTime() {
        let rollup: [[String: Any]] = [
            ["__typename": "CheckRun", "name": "test", "workflowName": "CI", "status": "COMPLETED",
             "conclusion": "SUCCESS", "startedAt": "2026-11-01T10:05:00Z"],
            ["__typename": "CheckRun", "name": "test", "workflowName": "CI", "status": "COMPLETED",
             "conclusion": "FAILURE", "startedAt": "2026-11-01T10:00:00Z"],
            ["__typename": "CheckRun", "name": "test", "workflowName": "Other", "status": "COMPLETED",
             "conclusion": "FAILURE", "startedAt": "2026-11-01T09:00:00Z"],
        ]
        let counted = AgentPanePullRequest.counted(rollup)
        #expect(AgentPanePullRequest.checks(counted) == .init(state: "failing", passed: 1, total: 2),
                "CI's newer success replaces its older failure; Other's test is another check")
    }

    /// The same name in another workflow is another check. Job labels repeat across workflows, so
    /// a base red called `test` must not excuse a head red called `test` that is a different job.
    @Test func aRedOfAnotherWorkflowWithTheSameNameIsNotExcused() {
        let base = AgentPanePullRequest.failing([Self.run("test", "FAILURE", workflow: 5, run: 10)])
        let head = [Self.run("test", "FAILURE", workflow: 6, run: 20), Self.run("test", "FAILURE", workflow: 5, run: 21)]
        #expect(AgentPanePullRequest.checkList(head, failingOnBase: base).map(\.onBase) == [false, true],
                "only the red of the workflow the base failed")
        #expect(AgentPanePullRequest.checks(head, failingOnBase: base).failingOnBase == 1)
    }

    /// A check that passes on the head is never marked, however red the base is: the mark says
    /// "this red is not yours", and there is no red to say it about.
    @Test func aPassingHeadCheckIsNeverMarked() {
        let base = AgentPanePullRequest.failing([Self.run("Verify / scripts", "FAILURE", workflow: 1, run: 10)])
        let head = [Self.run("Verify / scripts", "SUCCESS", workflow: 1, run: 20)]
        #expect(AgentPanePullRequest.checkList(head, failingOnBase: base).map(\.onBase) == [false])
        #expect(AgentPanePullRequest.checks(head, failingOnBase: base).failingOnBase == 0)
    }

    /// A base check still running is no evidence either: it has not failed yet, and a pull request
    /// does not wait on another commit's verdict to own its red.
    @Test func aBaseCheckStillRunningIsNoEvidence() {
        let base = [Self.run("Verify / scripts", "", workflow: 1, run: 10, status: "IN_PROGRESS")]
        #expect(AgentPanePullRequest.failing(base).isEmpty)
        let list = AgentPanePullRequest.checkList([Self.run("Verify / scripts", "FAILURE", workflow: 1, run: 20)],
                                                  failingOnBase: AgentPanePullRequest.failing(base))
        #expect(list.first?.onBase == false)
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
