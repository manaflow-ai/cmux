import Foundation
import Testing
@testable import CmuxControlSocket

/// A scriptable ``ControlCommandContext`` for driving the workspace-todo
/// coordinator domain without the app target.
@MainActor
final class FakeWorkspaceTodoControlCommandContext: ControlCommandContext {
    var statusResolution: ControlWorkspaceTodoStatusResolution = .tabManagerUnavailable
    var checklistResolution: ControlWorkspaceTodoChecklistResolution = .tabManagerUnavailable
    var mutationResolution: ControlWorkspaceTodoMutationResolution = .tabManagerUnavailable
    var setResolution: ControlWorkspaceTodoSetResolution = .tabManagerUnavailable
    var openResolution: ControlWorkspaceTodoOpenResolution = .tabManagerUnavailable

    var lastStatusSetRaw: String??
    var lastAdd: (text: String, stateRaw: String?, originRaw: String?)?
    var lastSetState: (itemID: UUID?, itemIndex: Int?, stateRaw: String)?
    var lastRemove: (itemID: UUID?, itemIndex: Int?)?
    var lastSetItems: [ControlWorkspaceTodoSetItemParam]?
    var lastOpenRequestedFocus: Bool?
    var lastWorkspaceID: UUID??

    func controlWorkspaceTaskStatus(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlWorkspaceTodoStatusResolution {
        lastWorkspaceID = workspaceID
        return statusResolution
    }

    func controlSetWorkspaceTaskStatus(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        statusRaw: String?
    ) -> ControlWorkspaceTodoStatusResolution {
        lastWorkspaceID = workspaceID
        lastStatusSetRaw = statusRaw
        return statusResolution
    }

    func controlWorkspaceTodoList(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlWorkspaceTodoChecklistResolution {
        lastWorkspaceID = workspaceID
        return checklistResolution
    }

    func controlWorkspaceTodoAdd(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        text: String,
        stateRaw: String?,
        originRaw: String?
    ) -> ControlWorkspaceTodoMutationResolution {
        lastAdd = (text, stateRaw, originRaw)
        return mutationResolution
    }

    func controlWorkspaceTodoSetState(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        itemID: UUID?,
        itemIndex: Int?,
        stateRaw: String
    ) -> ControlWorkspaceTodoMutationResolution {
        lastSetState = (itemID, itemIndex, stateRaw)
        return mutationResolution
    }

    func controlWorkspaceTodoRemove(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        itemID: UUID?,
        itemIndex: Int?
    ) -> ControlWorkspaceTodoMutationResolution {
        lastRemove = (itemID, itemIndex)
        return mutationResolution
    }

    func controlWorkspaceTodoClear(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlWorkspaceTodoMutationResolution {
        lastWorkspaceID = workspaceID
        return mutationResolution
    }

    func controlWorkspaceTodoSet(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        items: [ControlWorkspaceTodoSetItemParam]
    ) -> ControlWorkspaceTodoSetResolution {
        lastWorkspaceID = workspaceID
        lastSetItems = items
        return setResolution
    }

    func controlWorkspaceTodoOpen(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        requestedFocus: Bool
    ) -> ControlWorkspaceTodoOpenResolution {
        lastWorkspaceID = workspaceID
        lastOpenRequestedFocus = requestedFocus
        return openResolution
    }
}

@MainActor
@Suite("ControlCommandCoordinator workspace-todo domain")
struct ControlCommandCoordinatorWorkspaceTodoTests {
    func makeCoordinator() -> (ControlCommandCoordinator, FakeWorkspaceTodoControlCommandContext) {
        let context = FakeWorkspaceTodoControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        return (coordinator, context)
    }

    func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    private func statusSnapshot(_ workspaceID: UUID) -> ControlWorkspaceTodoStatusSnapshot {
        ControlWorkspaceTodoStatusSnapshot(
            workspaceID: workspaceID,
            effective: "review",
            inferred: "working",
            overrideStatus: "review",
            overrideInferredAt: "working",
            signals: ControlWorkspaceTodoStatusSnapshot.Signals(
                anyAgentNeedsInput: false,
                anyAgentRunning: true,
                anyOpenPullRequest: false,
                hasPullRequests: false,
                allPullRequestsMergedOrClosed: false,
                isGitDirty: true
            )
        )
    }

    @Test func statusGetShapesOverrideAndSignals() throws {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        context.statusResolution = .resolved(windowID: nil, status: statusSnapshot(workspaceID))
        let result = try #require(coordinator.handle(request("workspace.status.get")))
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected ok payload, got \(result)")
            return
        }
        #expect(payload["effective"] == .string("review"))
        #expect(payload["inferred"] == .string("working"))
        #expect(payload["override"] == .object([
            "status": .string("review"),
            "inferred_at_override": .string("working"),
        ]))
        #expect(payload["signals"] == .object([
            "any_agent_needs_input": .bool(false),
            "any_agent_running": .bool(true),
            "any_open_pull_request": .bool(false),
            "has_pull_requests": .bool(false),
            "all_pull_requests_merged_or_closed": .bool(false),
            "is_git_dirty": .bool(true),
        ]))
    }

    @Test func statusSetAutoCrossesTheSeamAsNil() throws {
        let (coordinator, context) = makeCoordinator()
        context.statusResolution = .resolved(windowID: nil, status: statusSnapshot(UUID()))
        _ = try #require(coordinator.handle(request("workspace.status.set", ["status": .string("auto")])))
        #expect(context.lastStatusSetRaw == .some(nil))

        _ = try #require(coordinator.handle(request("workspace.status.set", ["status": .string("done")])))
        #expect(context.lastStatusSetRaw == "done")
    }

    @Test func statusSetMissingStatusIsInvalidParams() throws {
        let (coordinator, _) = makeCoordinator()
        let result = try #require(coordinator.handle(request("workspace.status.set")))
        guard case .err(let code, _, _) = result else {
            Issue.record("expected err, got \(result)")
            return
        }
        #expect(code == "invalid_params")
    }

    @Test func statusSetUnknownLaneEchoesInvalidStatus() throws {
        let (coordinator, context) = makeCoordinator()
        context.statusResolution = .invalidStatus("blocked")
        let result = try #require(coordinator.handle(request("workspace.status.set", ["status": .string("blocked")])))
        guard case .err(let code, _, let data) = result else {
            Issue.record("expected err, got \(result)")
            return
        }
        #expect(code == "invalid_params")
        #expect(data == .object(["status": .string("blocked")]))
    }

    @Test func todoListShapesItemsWithIndexesAndProgress() throws {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        context.checklistResolution = .resolved(
            windowID: nil,
            checklist: ControlWorkspaceTodoChecklistSnapshot(
                workspaceID: workspaceID,
                items: [
                    ControlWorkspaceTodoChecklistSnapshot.Item(
                        id: firstID, text: "done thing", state: "completed", origin: "user"
                    ),
                    ControlWorkspaceTodoChecklistSnapshot.Item(
                        id: secondID, text: "next thing", state: "pending", origin: "agent"
                    ),
                ],
                completedCount: 1,
                firstUncheckedText: "next thing"
            )
        )
        let result = try #require(coordinator.handle(request("workspace.todo.list")))
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected ok payload, got \(result)")
            return
        }
        #expect(payload["items"] == .array([
            .object([
                "id": .string(firstID.uuidString),
                "index": .int(0),
                "text": .string("done thing"),
                "state": .string("completed"),
                "origin": .string("user"),
            ]),
            .object([
                "id": .string(secondID.uuidString),
                "index": .int(1),
                "text": .string("next thing"),
                "state": .string("pending"),
                "origin": .string("agent"),
            ]),
        ]))
        #expect(payload["progress"] == .object([
            "completed": .int(1),
            "total": .int(2),
            "first_unchecked_text": .string("next thing"),
        ]))
    }

    @Test func todoAddPassesTextStateOriginThrough() throws {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        let itemID = UUID()
        let item = ControlWorkspaceTodoChecklistSnapshot.Item(
            id: itemID, text: "write test", state: "in-progress", origin: "agent"
        )
        context.mutationResolution = .resolved(
            windowID: nil,
            item: item,
            removedCount: 0,
            checklist: ControlWorkspaceTodoChecklistSnapshot(
                workspaceID: workspaceID,
                items: [item],
                completedCount: 0,
                firstUncheckedText: "write test"
            )
        )
        let result = try #require(coordinator.handle(request("workspace.todo.add", [
            "text": .string("write test"),
            "state": .string("in-progress"),
            "origin": .string("agent"),
        ])))
        #expect(context.lastAdd?.text == "write test")
        #expect(context.lastAdd?.stateRaw == "in-progress")
        #expect(context.lastAdd?.originRaw == "agent")
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected ok payload, got \(result)")
            return
        }
        #expect(payload["item"] == .object([
            "id": .string(itemID.uuidString),
            "index": .int(0),
            "text": .string("write test"),
            "state": .string("in-progress"),
            "origin": .string("agent"),
        ]))
    }

    @Test func todoAddMissingTextIsInvalidParams() throws {
        let (coordinator, _) = makeCoordinator()
        let result = try #require(coordinator.handle(request("workspace.todo.add")))
        guard case .err(let code, _, _) = result else {
            Issue.record("expected err, got \(result)")
            return
        }
        #expect(code == "invalid_params")
    }

    @Test func todoSetStateAcceptsZeroBasedIndexSelector() throws {
        let (coordinator, context) = makeCoordinator()
        context.mutationResolution = .itemNotFound
        let result = try #require(coordinator.handle(request("workspace.todo.set_state", [
            "index": .int(3),
            "state": .string("completed"),
        ])))
        #expect(context.lastSetState?.itemIndex == 3)
        #expect(context.lastSetState?.itemID == nil)
        #expect(context.lastSetState?.stateRaw == "completed")
        guard case .err(let code, _, _) = result else {
            Issue.record("expected err, got \(result)")
            return
        }
        #expect(code == "not_found")
    }

    @Test func todoSetStateWithoutSelectorIsInvalidParams() throws {
        let (coordinator, _) = makeCoordinator()
        let result = try #require(coordinator.handle(request("workspace.todo.set_state", [
            "state": .string("completed"),
        ])))
        guard case .err(let code, _, _) = result else {
            Issue.record("expected err, got \(result)")
            return
        }
        #expect(code == "invalid_params")
    }

    @Test func todoRemoveAcceptsItemIDSelector() throws {
        let (coordinator, context) = makeCoordinator()
        let itemID = UUID()
        context.mutationResolution = .itemNotFound
        _ = try #require(coordinator.handle(request("workspace.todo.remove", [
            "id": .string(itemID.uuidString),
        ])))
        #expect(context.lastRemove?.itemID == itemID)
        #expect(context.lastRemove?.itemIndex == nil)
    }

    @Test func todoClearReportsRemovedCount() throws {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        context.mutationResolution = .resolved(
            windowID: nil,
            item: nil,
            removedCount: 4,
            checklist: ControlWorkspaceTodoChecklistSnapshot(
                workspaceID: workspaceID,
                items: [],
                completedCount: 0,
                firstUncheckedText: nil
            )
        )
        let result = try #require(coordinator.handle(request("workspace.todo.clear")))
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected ok payload, got \(result)")
            return
        }
        #expect(payload["removed_count"] == .int(4))
        #expect(payload["item"] == nil)
        #expect(payload["progress"] == .object([
            "completed": .int(0),
            "total": .int(0),
            "first_unchecked_text": .null,
        ]))
    }

    @Test func checklistFullMapsToInvalidState() throws {
        let (coordinator, context) = makeCoordinator()
        context.mutationResolution = .checklistFull
        let result = try #require(coordinator.handle(request("workspace.todo.add", [
            "text": .string("one too many"),
        ])))
        guard case .err(let code, _, _) = result else {
            Issue.record("expected err, got \(result)")
            return
        }
        #expect(code == "invalid_state")
    }

}
