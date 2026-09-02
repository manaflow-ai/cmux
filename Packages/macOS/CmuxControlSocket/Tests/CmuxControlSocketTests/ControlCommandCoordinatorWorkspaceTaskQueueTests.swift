import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator task queue")
struct ControlCommandCoordinatorWorkspaceTaskQueueTests {
    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    private func item(id: UUID = UUID()) -> ControlWorkspaceTaskQueueItem {
        ControlWorkspaceTaskQueueItem(
            id: id,
            text: "Ship the fix",
            state: "pending",
            workspaceID: UUID(),
            workspaceTitle: "Feature",
            windowID: nil,
            owningAgent: "claude",
            lastActivityAt: Date(timeIntervalSince1970: 10),
            targetWorkingDirectory: "/tmp/project",
            targetAgentCommand: "claude --continue",
            targetAgentName: "claude",
            boundWorkspaceID: nil
        )
    }

    @Test("queue list shapes a cross-workspace row")
    func listShapesQueueRows() throws {
        let context = FakeWorkspaceTodoControlCommandContext()
        let row = item()
        context.queueResolution = .resolved([row])
        let coordinator = ControlCommandCoordinator(context: context)
        let result = try #require(coordinator.handle(request(
            "workspace.todo.queue.list",
            ["status": .string("pending")]
        )))
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected queue list payload")
            return
        }
        #expect(payload["count"] == .int(1))
        #expect(payload["items"] != nil)
    }

    @Test("queue list forwards an explicit window selector")
    func listForwardsWindowSelector() throws {
        let context = FakeWorkspaceTodoControlCommandContext()
        let windowID = UUID()
        context.queueResolution = .resolved([])
        let coordinator = ControlCommandCoordinator(context: context)

        _ = try #require(coordinator.handle(request(
            "workspace.todo.queue.list",
            ["window_id": .string(windowID.uuidString)]
        )))

        #expect(context.lastQueueWindowID == windowID)
    }

    @Test("index queue selectors resolve against the requested window")
    func indexSelectorUsesWindowSelector() throws {
        let context = FakeWorkspaceTodoControlCommandContext()
        let row = item()
        let windowID = UUID()
        context.queueResolution = .resolved([row])
        context.queueDispatchResolution = .created(
            item: row,
            createdWorkspaceID: UUID(),
            windowID: windowID
        )
        let coordinator = ControlCommandCoordinator(context: context)

        _ = try #require(coordinator.handle(request(
            "workspace.todo.queue.dispatch",
            [
                "index": .int(0),
                "window_id": .string(windowID.uuidString),
            ]
        )))

        #expect(context.lastQueueWindowID == windowID)
    }

    @Test("dispatch response explicitly reports focus false")
    func dispatchIsFocusSafe() throws {
        let context = FakeWorkspaceTodoControlCommandContext()
        let row = item()
        context.queueDispatchResolution = .created(item: row, createdWorkspaceID: UUID(), windowID: nil)
        let coordinator = ControlCommandCoordinator(context: context)
        let result = try #require(coordinator.handle(request(
            "workspace.todo.queue.dispatch",
            ["item_id": .string(row.id.uuidString)]
        )))
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected dispatch payload")
            return
        }
        #expect(payload["focused"] == .bool(false))
    }

    @Test("reveal response reports no selection or focus")
    func revealIsFocusSafe() throws {
        let context = FakeWorkspaceTodoControlCommandContext()
        let row = item()
        context.queueRevealResolution = .revealed(item: row)
        let coordinator = ControlCommandCoordinator(context: context)
        let result = try #require(coordinator.handle(request(
            "workspace.todo.queue.reveal",
            ["item_id": .string(row.id.uuidString)]
        )))
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected reveal payload")
            return
        }
        #expect(payload["focused"] == .bool(false))
        #expect(payload["selected"] == .bool(false))
    }

    @Test("malformed scalar or array targets are rejected without clearing")
    func malformedTargetsAreRejected() throws {
        for target in [
            JSONValue.string("not an object"),
            JSONValue.array([.string("not an object")]),
        ] {
            let context = FakeWorkspaceTodoControlCommandContext()
            let row = item()
            context.queueStrings = ControlWorkspaceTaskQueueStrings(
                invalidTarget: "localized invalid target"
            )
            context.queueTargetResolution = .updated(row)
            let coordinator = ControlCommandCoordinator(context: context)

            let result = try #require(coordinator.handle(request(
                "workspace.todo.queue.target",
                [
                    "item_id": .string(row.id.uuidString),
                    "target": target,
                ]
            )))
            guard case .err(let code, let message, _) = result else {
                Issue.record("expected invalid target error, got \(result)")
                continue
            }
            #expect(code == "invalid_params")
            #expect(message == "localized invalid target")
            #expect(context.queueTargetCallCount == 0)
        }
    }

    @Test("null target explicitly clears the saved dispatch target")
    func nullTargetClearsSavedTarget() throws {
        let context = FakeWorkspaceTodoControlCommandContext()
        let row = item()
        context.queueTargetResolution = .updated(row)
        let coordinator = ControlCommandCoordinator(context: context)

        _ = try #require(coordinator.handle(request(
            "workspace.todo.queue.target",
            [
                "item_id": .string(row.id.uuidString),
                "target": .null,
            ]
        )))

        #expect(context.queueTargetCallCount == 1)
        #expect(context.lastQueueTarget?.workingDirectory == nil)
        #expect(context.lastQueueTarget?.agentCommand == nil)
        #expect(context.lastQueueTarget?.agentName == nil)
    }
}
