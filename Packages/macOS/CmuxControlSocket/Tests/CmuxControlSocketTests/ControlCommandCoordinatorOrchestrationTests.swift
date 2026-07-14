import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator orchestration domain")
struct ControlCommandCoordinatorOrchestrationTests {
    private func coordinator() -> (ControlCommandCoordinator, FakeOrchestrationControlCommandContext) {
        let context = FakeOrchestrationControlCommandContext()
        return (ControlCommandCoordinator(context: context), context)
    }

    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    private func summary(name: String = "issue-fleet") -> ControlOrchestrationSummary {
        ControlOrchestrationSummary(
            name: name,
            version: "1.0.0",
            description: "Demo",
            substrate: "worktree",
            agentIDs: ["claude"],
            sourceDisplay: "/src/issue-fleet",
            trustConfirmed: false,
            unansweredParameterKeys: ["repo_root"]
        )
    }

    @Test func listBuildsSummaryRows() throws {
        let (coordinator, context) = coordinator()
        context.listResolution = .resolved([summary()])

        guard case .ok(.object(let payload)) = coordinator.handle(request("orchestration.list")),
              case .array(let rows) = payload["orchestrations"],
              case .object(let row) = rows.first else {
            Issue.record("unexpected orchestration.list shape")
            return
        }
        #expect(row["name"] == .string("issue-fleet"))
        #expect(row["substrate"] == .string("worktree"))
        #expect(row["trust_confirmed"] == .bool(false))
        #expect(row["unanswered_parameters"] == .array([.string("repo_root")]))
    }

    @Test func infoMergesSummaryAndDetail() throws {
        let (coordinator, context) = coordinator()
        context.infoResolution = .resolved(
            summary: summary(),
            detail: .object(["parameters": .array([.object(["key": .string("repo_root")])])])
        )

        guard case .ok(.object(let payload)) = coordinator.handle(
            request("orchestration.info", ["name": .string("issue-fleet")])
        ) else {
            Issue.record("unexpected orchestration.info shape")
            return
        }
        #expect(payload["name"] == .string("issue-fleet"))
        #expect(payload["parameters"] != nil)
        #expect(context.infoCall == "issue-fleet")
    }

    @Test func infoRequiresNameAndMapsNotInstalled() throws {
        let (coordinator, context) = coordinator()
        _ = context
        guard case .err(let code, _, _) = coordinator.handle(request("orchestration.info")) else {
            Issue.record("expected error")
            return
        }
        #expect(code == "invalid_params")

        guard case .err(let missingCode, _, _) = coordinator.handle(
            request("orchestration.info", ["name": .string("ghost")])
        ) else {
            Issue.record("expected error")
            return
        }
        #expect(missingCode == "not_found")
    }

    @Test func planParsesTasksAndOverrides() throws {
        let (coordinator, context) = coordinator()
        context.planResolution = .resolved(plan: .object(["run_id": .string("r1")]), trustConfirmed: true)

        let result = coordinator.handle(request("orchestration.plan", [
            "name": .string("issue-fleet"),
            "tasks": .array([
                .string("fix the bug"),
                .object(["title": .string("add tests"), "body": .string("details"), "issue_number": .int(7)]),
            ]),
            "params": .object(["repo_root": .string("/repos/x"), "concurrency": .int(3)]),
            "agent": .string("claude"),
        ]))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("unexpected orchestration.plan shape")
            return
        }
        #expect(payload["trust_confirmed"] == .bool(true))
        let inputs = try #require(context.planCall)
        #expect(inputs.name == "issue-fleet")
        #expect(inputs.tasks.count == 2)
        #expect(inputs.tasks[0].title == "fix the bug")
        #expect(inputs.tasks[1].body == "details")
        #expect(inputs.tasks[1].issueNumber == 7)
        #expect(inputs.parameterOverrides["repo_root"] == "/repos/x")
        #expect(inputs.parameterOverrides["concurrency"] == "3")
        #expect(inputs.agentID == "claude")
    }

    @Test func planRejectsMalformedTasksAndParams() throws {
        let (coordinator, context) = coordinator()
        _ = context

        guard case .err(let code, _, _) = coordinator.handle(request("orchestration.plan", [
            "name": .string("x"),
            "tasks": .array([.object(["body": .string("no title")])]),
        ])) else {
            Issue.record("expected error")
            return
        }
        #expect(code == "invalid_params")

        guard case .err(let paramsCode, _, _) = coordinator.handle(request("orchestration.plan", [
            "name": .string("x"),
            "params": .object(["bad": .array([])]),
        ])) else {
            Issue.record("expected error")
            return
        }
        #expect(paramsCode == "invalid_params")
    }

    @Test func runMapsTrustConfirmationFlow() throws {
        let (coordinator, context) = coordinator()
        context.runResolution = .needsTrustConfirmation(trust: .object(["substrate": .string("script")]))

        guard case .err(let code, _, let data) = coordinator.handle(request("orchestration.run", [
            "name": .string("issue-fleet"),
            "tasks": .array([.string("t")]),
        ])) else {
            Issue.record("expected error")
            return
        }
        #expect(code == "needs_confirmation")
        guard case .object(let dataObject)? = data else {
            Issue.record("expected trust data")
            return
        }
        #expect(dataObject["trust"] == .object(["substrate": .string("script")]))
        #expect(context.runCall?.confirmTrust == false)

        context.runResolution = .started(.object(["run_id": .string("r1")]))
        guard case .ok(.object(let payload)) = coordinator.handle(request("orchestration.run", [
            "name": .string("issue-fleet"),
            "tasks": .array([.string("t")]),
            "confirm_trust": .bool(true),
        ])) else {
            Issue.record("expected started payload")
            return
        }
        #expect(payload["run_id"] == .string("r1"))
        #expect(context.runCall?.confirmTrust == true)
    }

    @Test func planFailureMapsToInvalidParams() throws {
        let (coordinator, context) = coordinator()
        context.runResolution = .planFailed("Unanswered parameter(s): repo_root")

        guard case .err(let code, let message, _) = coordinator.handle(request("orchestration.run", [
            "name": .string("issue-fleet"),
        ])) else {
            Issue.record("expected error")
            return
        }
        #expect(code == "invalid_params")
        #expect(message.contains("repo_root"))
    }

    @Test func unknownOrchestrationMethodFallsThrough() throws {
        let (coordinator, context) = coordinator()
        _ = context
        #expect(coordinator.handle(request("orchestration.unknown")) == nil)
    }
}
