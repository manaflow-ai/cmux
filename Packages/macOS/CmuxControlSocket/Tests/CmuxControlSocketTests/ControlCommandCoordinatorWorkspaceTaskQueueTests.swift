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
}
