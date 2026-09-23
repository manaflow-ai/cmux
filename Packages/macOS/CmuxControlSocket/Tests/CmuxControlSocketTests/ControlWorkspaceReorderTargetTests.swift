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
}
