import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
struct ControlWorkspaceReorderTargetTests {
    @Test(arguments: ["before_workspace_id", "after_workspace_id"])
    func unresolvedRelativeTargetReportsNotFound(key: String) {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let result = coordinator.handle(ControlRequest(id: .int(1), method: "workspace.reorder", params: [
            "workspace_id": .string(UUID().uuidString),
            key: .string("workspace:999999"),
            "dry_run": .bool(true)
        ]))
        guard case .err(let code, _, _) = result else {
            Issue.record("An unknown relative target must fail")
            return
        }
        #expect(code == "not_found")
        #expect(context.reorderCall == nil)
    }

    @Test(arguments: ["before_workspace_id", "after_workspace_id"])
    func unresolvedTargetStillConflictsWithIndex(key: String) {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let result = coordinator.handle(ControlRequest(id: .int(1), method: "workspace.reorder", params: [
            "workspace_id": .string(UUID().uuidString),
            key: .string("workspace:999999"),
            "index": .int(0)
        ]))
        guard case .err(let code, _, _) = result else {
            Issue.record("Conflicting targets must fail")
            return
        }
        #expect(code == "invalid_params")
        #expect(context.reorderCall == nil)
    }

    @Test(arguments: ["before_workspace_id", "after_workspace_id"], [true, false])
    func knownRelativeTargetReachesPlannerWithoutIndex(key: String, dryRun: Bool) throws {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let targetID = UUID()
        let workspaceRef = coordinator.ensureRef(kind: .workspace, uuid: workspaceID)
        let targetRef = coordinator.ensureRef(kind: .workspace, uuid: targetID)
        context.reorderResolution = .resolved(
            windowID: nil,
            plan: ControlWorkspaceReorderPlanItem(workspaceID: workspaceID, fromIndex: 1, toIndex: 0)
        )
        let result = coordinator.handle(ControlRequest(id: .int(1), method: "workspace.reorder", params: [
            "workspace_id": .string(workspaceRef), key: .string(targetRef), "dry_run": .bool(dryRun)
        ]))
        guard case .ok = result else {
            Issue.record("A known relative target must succeed")
            return
        }
        let call = try #require(context.reorderCall)
        #expect(call.workspaceID == workspaceID)
        #expect(call.index == nil)
        #expect(call.before == (key == "before_workspace_id" ? targetID : nil))
        #expect(call.after == (key == "after_workspace_id" ? targetID : nil))
        #expect(call.dryRun == dryRun)
    }

    // #13499: a refused placement is an error that still names the row, its
    // window, and the slot it stayed in, so a caller can undo its paint.
    @Test(arguments: [true, false])
    func refusedPlacementReportsRejectedWithPlan(dryRun: Bool) throws {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let windowID = UUID()
        let workspaceRef = coordinator.ensureRef(kind: .workspace, uuid: workspaceID)
        context.reorderResolution = .rejected(
            windowID: windowID,
            plan: ControlWorkspaceReorderPlanItem(workspaceID: workspaceID, fromIndex: 1, toIndex: 1)
        )
        let result = coordinator.handle(ControlRequest(id: .int(1), method: "workspace.reorder", params: [
            "workspace_id": .string(workspaceRef), "index": .int(0), "dry_run": .bool(dryRun)
        ]))
        guard case .err(let code, _, let data) = result, case .object(let object)? = data else {
            Issue.record("A refused placement must fail with data")
            return
        }
        #expect(code == "rejected")
        #expect(object["workspace_id"] == .string(workspaceID.uuidString))
        #expect(object["window_id"] == .string(windowID.uuidString))
        #expect(object["from_index"] == .int(1))
        #expect(object["to_index"] == .int(1))
        #expect(object["requested_index"] == .int(0))
        #expect(object["dry_run"] == .bool(dryRun))
        #expect(try #require(context.reorderCall).index == 0)
    }
}
