import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon

/// Action handlers for window membership (every drag transition is also an
/// action, so the palette, a right-click, a shortcut, and the CLI reach it):
/// move workspaces (the right-clicked one, or the sidebar multi-selection it
/// belongs to) or a whole workspace group to another window or a new one.
/// Window membership is frontend-local, so none of these sends a daemon
/// command; tab moves to a new window stay in `TabHandlers`.
enum WindowMembershipHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        // Into a new window beside the window they leave (`WindowManager.openMovedWindow`).
        let windows = context.services.windows
        let newWindow = { (ids: [String]) in windows.openMovedWindow(ids, from: windows.moveOrigin(of: ids.first), select: ActionRunScope.viewChangeAllowed()) }
        registry.bind("moveWorkspaceToWindow", run: { try move(workspaces($0, context), toWindow: $0, context) })
        registry.bind("moveWorkspaceToNewWindow", run: { try newWindow(workspaces($0, context)) })
        registry.bind("workspaceGroup.moveToWindow", run: { try move(groupMembers($0, context), toWindow: $0, context) })
        registry.bind("workspaceGroup.moveToNewWindow", run: { try newWindow(groupMembers($0, context)) })
    }

    /// The targeted workspace, widened to its window's sidebar selection
    /// when it is part of a multi-selection there.
    static func workspaces(_ invocation: ActionInvocation, _ context: AppActionContext) throws -> [String] {
        let id = try context.workspace(invocation).model.id
        let windows = context.services.windows
        guard let owner = windows.registry.value.owner(of: id), let controller = windows.controller(for: owner) else { return [id] }
        let selection = controller.sidebar.model.orderedSelection.map(\.rawValue)
        return selection.count > 1 && selection.contains(id) ? selection : [id]
    }

    /// A person's row verb (Pin, Duplicate, Mute, New Workspace Below, Close Other) on the targeted
    /// workspace: ``workspaces(_:_:)`` for a menu, key or palette run; the target alone for the CLI
    /// and MCP, which name their workspace, and for a row's own control (`closesRowOnly`).
    static func rowTargets(_ invocation: ActionInvocation, _ context: AppActionContext) throws -> [WorkspaceModel] {
        let workspace = try context.workspace(invocation).model
        guard invocation.origin == .user, !invocation.closesRowOnly else { return [workspace] }
        let models = try workspaces(invocation, context).compactMap(context.services.workspace(id:))
        return models.isEmpty ? [workspace] : models
    }

    /// Every workspace of the targeted group: its sidebar rows in order (`WorkspaceGroupClose.members`),
    /// then any other the personal store places in it. A personal group's membership lives in the
    /// personal store, not on `WorkspaceModel.group`, which reading the daemon's workspaces missed.
    static func groupMembers(_ invocation: ActionInvocation, _ context: AppActionContext) throws -> [String] {
        let group = try context.group(invocation)
        let personal = context.services.machines.local.store.personal.workspaces.filter { $0.group == group.id }.map(\.workspaceKey.rawValue)
        var seen = Set<String>()
        let members = (WorkspaceGroupClose.members(of: group, context).map(\.0.id) + personal).filter { seen.insert($0).inserted }
        guard !members.isEmpty else { throw ActionFailure.invalidTarget(RefusalStrings.workspaceNotInGroup) }
        return members
    }

    /// Into the window named by the `window` argument (or target).
    static func move(_ ids: [String], toWindow invocation: ActionInvocation, _ context: AppActionContext) throws {
        let target = try context.window(invocation)
        guard !context.services.windows.registry.value.crossesIncognito(ids, to: target.state.id) else {
            throw ActionFailure.invalidTarget(RefusalStrings.incognitoMismatch)
        }
        target.sidebar.accept(ids.map(SidebarWorkspaceID.init), at: nil)
        context.services.windows.bringToFront(target)
    }
}
