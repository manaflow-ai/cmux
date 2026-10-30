import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Testing

/// Close Workspaces in Group, then the toast's Undo, on the real daemon and the app's launch
/// window: the close deletes the unpinned group with its workspace (`PersonalGroupPin`), and Undo
/// brings back both, the workspace in its group. The close's group cleanup
/// (`PersonalGroupLife.deleteWhenEmpty`) ends within `PersonalGroupLife.closeSettleLimit` and
/// never deletes the group Undo restored.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct WorkspaceGroupCloseUndoTests {
    @Test func undoAfterClosingAGroupRestoresTheGroupWithItsWorkspace() async throws {
        let launch = try await GroupedAppLaunch.start()
        let result: Result<Void, any Error>
        do {
            try await Self.closeAndUndo(launch)
            result = .success(())
        } catch { result = .failure(error) }
        await launch.stop()
        try result.get()
    }

    private static func closeAndUndo(_ launch: GroupedAppLaunch) async throws {
        let services = launch.services, context = AppActionContext(services: services)
        let personal = services.machines.local.store.personal
        let groupName = try #require(personal.group(launch.group)?.name)
        let workspaceName = launch.workspace.name
        try #require(personal.group(launch.group)?.pinned == false, "the launch group starts pinned")

        // The toast shows in a window that keeps a workspace: give the launch window a loose one
        // when the group's workspace is all it holds.
        if WorkspaceBulkClose.survivor(closing: [launch.workspace.id], context) == nil {
            _ = services.registry.perform("workspace.newOnMachine", invocation: ActionInvocation(
                arguments: ["machine": .string(MachineRegistry.localID)], origin: .cli))
            try await PinnedPageTests.until({ WorkspaceBulkClose.survivor(closing: [launch.workspace.id], context) != nil },
                                            within: .seconds(30), report: { "no window keeps a workspace once the group closes" })
        }
        let undoWindow = try #require(WorkspaceBulkClose.survivor(closing: [launch.workspace.id], context))

        // A person's Close Workspaces in Group, past its question.
        let refusal = services.registry.capturingRefusal {
            _ = services.registry.perform("workspaceGroup.closeWorkspaces", invocation: ActionInvocation(
                target: ActionTargetRef(kind: .workspaceGroup, id: launch.group.rawValue), origin: .user).confirmed())
        }
        try #require(refusal == nil, "Close Workspaces in Group refused: \(refusal ?? "")")
        try await PinnedPageTests.until({
            personal.group(launch.group) == nil && services.workspace(id: launch.workspace.id) == nil
        }, within: .seconds(30), report: {
            "group \(String(describing: personal.group(launch.group)?.name)), workspace open \(services.workspace(id: launch.workspace.id) != nil)"
        })
        #expect(CmuxToastCenter.shared.toasts(in: undoWindow).contains { $0.id == WorkspaceGroupClose.toastID },
                "the close showed no Undo toast")

        // Undo: the workspace comes back, in its group.
        #expect(CmuxToastCenter.shared.runAction(id: WorkspaceGroupClose.toastID, in: undoWindow), "the toast had no Undo to run")
        func restored() -> WorkspaceGroupID? {
            guard let group = personal.groups.first(where: { $0.name == groupName }) else { return nil }
            return context.workspaces(inPersonalGroup: group.id).contains { $0.name == workspaceName } ? group.id : nil
        }
        try await PinnedPageTests.until({ restored() != nil }, within: .seconds(30), report: {
            "groups \(personal.groups.map(\.name)), open \(services.machines.daemons.flatMap(\.store.workspaces).map(\.name))"
        })

        // The close's cleanup has had its whole deadline: the restored group is still there, still holding the workspace.
        try await Task.sleep(for: PersonalGroupLife.closeSettleLimit + .seconds(1))
        #expect(restored() != nil, "the restored group or its workspace went after Undo: groups \(personal.groups.map(\.name))")
    }
}
