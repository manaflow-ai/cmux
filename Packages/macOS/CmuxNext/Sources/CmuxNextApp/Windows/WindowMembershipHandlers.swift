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
        registry.bind("moveWorkspaceToWindow", run: { invocation in
            let ids = try workspaces(invocation, context)
            try move(ids, toWindow: invocation, context)
        })
        registry.bind("moveWorkspaceToNewWindow", run: { invocation in
            let ids = try workspaces(invocation, context)
            toNewWindow(ids, context)
        })
        registry.bind("workspaceGroup.moveToWindow", run: { invocation in
            try move(groupMembers(invocation, context), toWindow: invocation, context)
        })
        registry.bind("workspaceGroup.moveToNewWindow", run: { invocation in
            toNewWindow(try groupMembers(invocation, context), context)
        })
    }

    /// The targeted workspace, widened to its window's sidebar selection
    /// when it is part of a multi-selection there.
    static func workspaces(_ invocation: ActionInvocation, _ context: AppActionContext) throws -> [String] {
        let id = try context.workspace(invocation).model.id
        let windows = context.services.windows!
        guard let owner = windows.registry.value.owner(of: id), let controller = windows.controller(for: owner) else { return [id] }
        let selection = controller.sidebar.model.orderedSelection.map(\.rawValue)
        return selection.count > 1 && selection.contains(id) ? selection : [id]
    }

    /// Every workspace of the targeted group, in daemon order.
    static func groupMembers(_ invocation: ActionInvocation, _ context: AppActionContext) throws -> [String] {
        let group = try context.group(invocation)
        let members = context.store.workspaces.filter { $0.group == group.id }.map(\.id)
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

    /// Into a new window cascaded from the window they leave. When they are
    /// every workspace of that window, the window itself moves there (like
    /// dragging them out): no second window opens and none closes.
    static func toNewWindow(_ ids: [String], _ context: AppActionContext) {
        let windows = context.services.windows!
        let source = ids.first.flatMap { windows.registry.value.owner(of: $0) }.flatMap(windows.controller(for:))
        let frame = source?.window?.frame.offsetBy(dx: 28, dy: -28)
        if let source, let frame, Set(ids) == Set(windows.registry.members(of: source.state.id)) {
            source.window?.setFrame(frame, display: true)
            windows.bringToFront(source)
            windows.stateDidChange(source.state)
            return
        }
        guard let controller = windows.openWindow(workspaces: ids, frame: frame) else { return }
        windows.bringToFront(controller)
    }
}
