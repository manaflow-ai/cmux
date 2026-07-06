import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
private final class FakeFleetControlCommandContext: ControlCommandContext {
    private(set) var calls: [String] = []
    private(set) var createInputs: ControlFleetCreateInputs?
    private(set) var lifecycleFleetIDs: [String] = []
    private(set) var taskAddInputs: ControlFleetTaskAddInputs?
    private(set) var taskListArgs: (fleetID: String?, state: ControlFleetTaskStateName?)?
    private(set) var taskIDs: [String] = []

    var listSnapshots: [ControlFleetSnapshot] = []
    var statusResolution: ControlFleetStatusResolution = .ok(ControlFleetStatusSnapshot(isRunning: false, fleets: []))
    var createResolution: ControlFleetCreateResolution = .engineUnavailable
    var startResolution: ControlFleetLifecycleResolution = .engineUnavailable
    var stopResolution: ControlFleetLifecycleResolution = .engineUnavailable
    var taskAddResolution: ControlFleetTaskAddResolution = .engineUnavailable
    var taskListResolution: ControlFleetTaskListResolution = .ok([])
    var taskRetryResolution: ControlFleetTaskActionResolution = .engineUnavailable
    var taskCancelResolution: ControlFleetTaskActionResolution = .engineUnavailable
    var taskOpenResolution: ControlFleetTaskOpenResolution = .engineUnavailable

    func controlFleetList() -> [ControlFleetSnapshot] {
        calls.append("list")
        return listSnapshots
    }

    func controlFleetStatus(fleetID: String?) -> ControlFleetStatusResolution {
        calls.append("status:\(fleetID ?? "<nil>")")
        return statusResolution
    }

    func controlFleetCreate(inputs: ControlFleetCreateInputs) -> ControlFleetCreateResolution {
        calls.append("create")
        createInputs = inputs
        return createResolution
    }

    func controlFleetStart(fleetID: String) -> ControlFleetLifecycleResolution {
        calls.append("start")
        lifecycleFleetIDs.append(fleetID)
        return startResolution
    }

    func controlFleetStop(fleetID: String) -> ControlFleetLifecycleResolution {
        calls.append("stop")
        lifecycleFleetIDs.append(fleetID)
        return stopResolution
    }

    func controlFleetTaskAdd(inputs: ControlFleetTaskAddInputs) -> ControlFleetTaskAddResolution {
        calls.append("task.add")
        taskAddInputs = inputs
        return taskAddResolution
    }

    func controlFleetTaskList(
        fleetID: String?,
        state: ControlFleetTaskStateName?
    ) -> ControlFleetTaskListResolution {
        calls.append("task.list")
        taskListArgs = (fleetID, state)
        return taskListResolution
    }

    func controlFleetTaskRetry(taskID: String) -> ControlFleetTaskActionResolution {
        calls.append("task.retry")
        taskIDs.append(taskID)
        return taskRetryResolution
    }

    func controlFleetTaskCancel(taskID: String) -> ControlFleetTaskActionResolution {
        calls.append("task.cancel")
        taskIDs.append(taskID)
        return taskCancelResolution
    }

    func controlFleetTaskOpen(taskID: String) -> ControlFleetTaskOpenResolution {
        calls.append("task.open")
        taskIDs.append(taskID)
        return taskOpenResolution
    }
}

@MainActor
@Suite("ControlCommandCoordinator Fleet domain")
struct ControlCommandCoordinatorFleetTests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeFleetControlCommandContext) {
        let context = FakeFleetControlCommandContext()
        return (ControlCommandCoordinator(context: context), context)
    }

    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    private var fleet: ControlFleetSnapshot {
        ControlFleetSnapshot(
            fleetID: "fleet-a",
            name: "Fleet A",
            repoRoot: "/repo/a",
            isRunning: true,
            taskCounts: [.queued: 2, .running: 1, .failed: 3]
        )
    }

    private var fullTask: ControlFleetTaskSnapshot {
        ControlFleetTaskSnapshot(
            taskID: "task-full",
            fleetID: "fleet-a",
            source: "github",
            title: "Implement feature",
            state: .awaitingReview,
            isBlocked: true,
            attempts: 2,
            priority: 7,
            labels: ["bug", "backend"],
            url: "https://example.com/task",
            workspaceID: "workspace-raw",
            surfaceID: "surface-raw",
            directoryPath: "/repo/a",
            branch: "feature/fleet",
            pullRequest: ControlFleetTaskPullRequest(url: "https://example.com/pr/1", status: "open"),
            lastError: "needs review",
            createdAt: 1_700_000_000.25,
            updatedAt: 1_700_000_030.5
        )
    }

    private var minimalTask: ControlFleetTaskSnapshot {
        ControlFleetTaskSnapshot(
            taskID: "task-min",
            fleetID: "fleet-a",
            source: "local",
            title: "Local task",
            state: .queued,
            isBlocked: false,
            attempts: 0,
            priority: nil,
            labels: [],
            url: nil,
            workspaceID: nil,
            surfaceID: nil,
            directoryPath: nil,
            branch: nil,
            pullRequest: nil,
            lastError: nil,
            createdAt: 10,
            updatedAt: 20
        )
    }

    private var fleetPayload: JSONValue {
        .object([
            "fleet_id": .string("fleet-a"),
            "name": .string("Fleet A"),
            "repo_root": .string("/repo/a"),
            "running": .bool(true),
            "counts": .object([
                "queued": .int(2),
                "provisioning": .int(0),
                "launching": .int(0),
                "running": .int(1),
                "needs_input": .int(0),
                "stalled": .int(0),
                "retry_backoff": .int(0),
                "awaiting_review": .int(0),
                "done": .int(0),
                "failed": .int(3),
                "cancelled": .int(0),
            ]),
        ])
    }

    private var fullTaskPayload: JSONValue {
        .object([
            "task_id": .string("task-full"),
            "fleet_id": .string("fleet-a"),
            "source": .string("github"),
            "title": .string("Implement feature"),
            "state": .string("awaiting_review"),
            "blocked": .bool(true),
            "attempts": .int(2),
            "priority": .int(7),
            "labels": .array([.string("bug"), .string("backend")]),
            "url": .string("https://example.com/task"),
            "workspace_id": .string("workspace-raw"),
            "surface_id": .string("surface-raw"),
            "directory": .string("/repo/a"),
            "branch": .string("feature/fleet"),
            "pr": .object(["url": .string("https://example.com/pr/1"), "status": .string("open")]),
            "last_error": .string("needs review"),
            "created_at": .double(1_700_000_000.25),
            "updated_at": .double(1_700_000_030.5),
        ])
    }

    private var minimalTaskPayload: JSONValue {
        .object([
            "task_id": .string("task-min"),
            "fleet_id": .string("fleet-a"),
            "source": .string("local"),
            "title": .string("Local task"),
            "state": .string("queued"),
            "blocked": .bool(false),
            "attempts": .int(0),
            "priority": .null,
            "labels": .array([]),
            "url": .null,
            "workspace_id": .null,
            "surface_id": .null,
            "directory": .null,
            "branch": .null,
            "pr": .null,
            "last_error": .null,
            "created_at": .double(10),
            "updated_at": .double(20),
        ])
    }

    @Test func routesEveryFleetMethodAndIgnoresUnknownMethods() {
        let (coordinator, context) = makeCoordinator()
        context.createResolution = .created(fleet)
        context.startResolution = .ok(fleet)
        context.stopResolution = .ok(fleet)
        context.taskAddResolution = .added(fullTask)
        context.taskRetryResolution = .ok(fullTask)
        context.taskCancelResolution = .ok(fullTask)
        context.taskOpenResolution = .workspaceUnavailable

        _ = coordinator.handle(request("fleet.list"))
        _ = coordinator.handle(request("fleet.status"))
        _ = coordinator.handle(request("fleet.create", ["name": .string("N"), "repo_root": .string("/r")]))
        _ = coordinator.handle(request("fleet.start", ["fleet_id": .string("fleet-a")]))
        _ = coordinator.handle(request("fleet.stop", ["fleet_id": .string("fleet-a")]))
        _ = coordinator.handle(request("fleet.task.add", ["fleet_id": .string("fleet-a"), "title": .string("T")]))
        _ = coordinator.handle(request("fleet.task.list"))
        _ = coordinator.handle(request("fleet.task.retry", ["task_id": .string("task-a")]))
        _ = coordinator.handle(request("fleet.task.cancel", ["task_id": .string("task-a")]))
        _ = coordinator.handle(request("fleet.task.open", ["task_id": .string("task-a")]))

        #expect(context.calls == [
            "list", "status:<nil>", "create", "start", "stop",
            "task.add", "task.list", "task.retry", "task.cancel", "task.open",
        ])
        #expect(coordinator.handleFleet(request("fleet.unknown")) == nil)
        #expect(coordinator.handle(request("fleet.unknown")) == nil)
        #expect(coordinator.handleFleet(request("workspace.list")) == nil)
    }

    @Test func encodesSuccessPayloadsExactly() {
        let workspaceID = UUID()
        let (coordinator, context) = makeCoordinator()
        context.listSnapshots = [fleet]
        context.statusResolution = .ok(ControlFleetStatusSnapshot(isRunning: true, fleets: [fleet]))
        context.createResolution = .created(fleet)
        context.startResolution = .ok(fleet)
        context.taskAddResolution = .added(fullTask)
        context.taskListResolution = .ok([fullTask, minimalTask])
        context.taskRetryResolution = .ok(minimalTask)
        context.taskOpenResolution = .opened(workspaceID: workspaceID)

        #expect(coordinator.handle(request("fleet.list")) == .ok(.object(["fleets": .array([fleetPayload])])))
        #expect(coordinator.handle(request("fleet.status")) == .ok(.object([
            "running": .bool(true),
            "fleets": .array([fleetPayload]),
        ])))
        #expect(coordinator.handle(request("fleet.create", [
            "name": .string("Fleet A"),
            "repo_root": .string("/repo/a"),
        ])) == .ok(.object(["fleet": fleetPayload])))
        #expect(coordinator.handle(request("fleet.start", [
            "fleet_id": .string("fleet-a"),
        ])) == .ok(.object(["fleet": fleetPayload])))
        #expect(coordinator.handle(request("fleet.task.add", [
            "fleet_id": .string("fleet-a"),
            "title": .string("Implement feature"),
        ])) == .ok(.object(["task": fullTaskPayload])))
        #expect(coordinator.handle(request("fleet.task.list")) == .ok(.object([
            "tasks": .array([fullTaskPayload, minimalTaskPayload]),
        ])))
        #expect(coordinator.handle(request("fleet.task.retry", [
            "task_id": .string("task-min"),
        ])) == .ok(.object(["task": minimalTaskPayload])))

        let workspaceRef = coordinator.handles.ensureRef(kind: .workspace, uuid: workspaceID)
        #expect(coordinator.handle(request("fleet.task.open", [
            "task_id": .string("task-full"),
        ])) == .ok(.object([
            "task_id": .string("task-full"),
            "workspace_id": .string(workspaceRef),
        ])))
    }

    @Test func validatesRequiredAndTypedParams() {
        let (coordinator, _) = makeCoordinator()
        let cases: [(String, [String: JSONValue])] = [
            ("fleet.create", ["repo_root": .string("/r")]),
            ("fleet.create", ["name": .string("N")]),
            ("fleet.create", ["name": .string("N"), "repo_root": .string("/r"), "max_concurrent": .int(0)]),
            ("fleet.start", [:]),
            ("fleet.stop", [:]),
            ("fleet.task.add", ["title": .string("T")]),
            ("fleet.task.add", ["fleet_id": .string("fleet-a")]),
            ("fleet.task.list", ["state": .string("bogus")]),
            ("fleet.task.retry", [:]),
            ("fleet.task.cancel", [:]),
            ("fleet.task.open", [:]),
        ]

        for (method, params) in cases {
            guard case .err(let code, _, _) = coordinator.handle(request(method, params)) else {
                Issue.record("expected invalid_params for \(method)")
                continue
            }
            #expect(code == "invalid_params", "for \(method)")
        }
    }

    @Test func mapsSeamErrorsToWireCodes() {
        let (coordinator, context) = makeCoordinator()
        context.createResolution = .engineUnavailable
        context.statusResolution = .fleetNotFound("fleet-missing")
        context.taskRetryResolution = .taskNotFound("task-missing")
        context.taskCancelResolution = .invalidState(current: .running)
        context.taskOpenResolution = .workspaceUnavailable

        #expect(errorCode(coordinator.handle(request("fleet.create", [
            "name": .string("N"),
            "repo_root": .string("/r"),
        ]))) == "unavailable")
        #expect(errorCode(coordinator.handle(request("fleet.status", [
            "fleet_id": .string("fleet-missing"),
        ]))) == "not_found")
        #expect(errorCode(coordinator.handle(request("fleet.task.retry", [
            "task_id": .string("task-missing"),
        ]))) == "not_found")
        let invalidState = coordinator.handle(request("fleet.task.cancel", ["task_id": .string("task-a")]))
        #expect(errorCode(invalidState) == "invalid_state")
        if case .err(_, let message, _) = invalidState {
            #expect(message.contains("running"))
        }
        #expect(errorCode(coordinator.handle(request("fleet.task.open", [
            "task_id": .string("task-a"),
        ]))) == "invalid_state")
    }

    @Test func trimsArgumentsAndParsesStateFilter() {
        let (coordinator, context) = makeCoordinator()
        context.createResolution = .created(fleet)
        context.startResolution = .ok(fleet)
        context.taskAddResolution = .added(minimalTask)

        _ = coordinator.handle(request("fleet.create", [
            "name": .string("  Fleet A  "),
            "repo_root": .string("  /repo/a  "),
            "agent_command": .string("  codex exec  "),
            "max_concurrent": .string("3"),
        ]))
        #expect(context.createInputs == ControlFleetCreateInputs(
            name: "Fleet A",
            repoRoot: "/repo/a",
            agentCommand: "codex exec",
            maxConcurrent: 3
        ))

        _ = coordinator.handle(request("fleet.start", ["fleet_id": .string("  fleet-a  ")]))
        _ = coordinator.handle(request("fleet.task.add", [
            "fleet_id": .string("  fleet-a  "),
            "title": .string("  Do work  "),
            "body": .string("  body  "),
            "priority": .string("5"),
        ]))
        _ = coordinator.handle(request("fleet.task.list", [
            "fleet_id": .string("  fleet-a  "),
            "state": .string("running"),
        ]))
        _ = coordinator.handle(request("fleet.task.retry", ["task_id": .string("  task-a  ")]))

        #expect(context.lifecycleFleetIDs == ["fleet-a"])
        #expect(context.taskAddInputs == ControlFleetTaskAddInputs(
            fleetID: "fleet-a",
            title: "Do work",
            body: "body",
            priority: 5
        ))
        #expect(context.taskListArgs?.fleetID == "fleet-a")
        #expect(context.taskListArgs?.state == .running)
        #expect(context.taskIDs == ["task-a"])
    }

    private func errorCode(_ result: ControlCallResult?) -> String? {
        guard case .err(let code, _, _) = result else { return nil }
        return code
    }
}
