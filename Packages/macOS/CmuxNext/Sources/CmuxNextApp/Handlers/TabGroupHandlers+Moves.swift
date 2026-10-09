import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon

// Whole-group moves: reorder in the strip, new split, new column, another
// or a new workspace, and a new window.
extension TabGroupHandlers {
    static func bindMoves(_ bind: Binder, _ ctx: AppActionContext) {
        bind("tabGroup.moveLeft") { reorder($0, forward: false, ctx) }
        bind("tabGroup.moveRight") { reorder($0, forward: true, ctx) }
        bind("tabGroup.moveToNewSplit") { invocation in
            guard let (group, pane) = group(invocation, ctx) else { return }
            let edge: PaneEdge = switch invocation["direction"]?.stringValue {
            case "left": .left
            case "up": .top
            case "down": .bottom
            default: .right
            }
            let handle = pane.handle
            run("move-tab-group-to-split", pane: pane, ctx) { c, t in
                _ = try await c.moveTabGroupToSplit(group, pane: handle, edge: edge, transaction: t)
            }
        }
        bind("tabGroup.moveToNewColumn") { invocation in
            guard let (group, pane) = group(invocation, ctx) else { return }
            let handle = pane.handle
            run("move-tab-group-to-column", pane: pane, ctx) { c, t in
                _ = try await c.moveTabGroupToColumn(group, target: .pane(handle), transaction: t)
            }
        }
        bind("tabGroup.moveToWorkspace") { invocation in
            guard let (group, pane) = group(invocation, ctx), let workspace = ctx.workspaceArgument(invocation) else { return }
            guard !ctx.services.windows.crossesIncognito(from: ctx.services.workspaceID(of: pane), to: workspace.id) else {
                return ctx.refuse(RefusalStrings.incognitoMismatch)
            }
            let screen = workspace.screens.first
            guard let target = screen?.defaultPane.flatMap({ screen?.pane($0) }) ?? screen?.panes.first
                ?? ctx.refuse(RefusalStrings.workspaceHasNoPane(workspace.id)) else { return }
            // Workspaces never mix machines: a workspace on another machine is refused.
            guard TabGroupMoves.owner(of: group, target: target, services: ctx.services) != nil else {
                return ctx.refuse(RefusalStrings.otherMachine)
            }
            let handle = target.handle, index = target.tabs.count
            run("move-tab-group", pane: pane, ctx) { c, t in
                _ = try await c.moveTabGroup(group, to: handle, index: index, transaction: t)
            }
        }
        bind("tabGroup.moveToNewWorkspace") { moveToNewWorkspace($0, newWindow: false, ctx) }
        bind("tabGroup.moveToNewWindow") { moveToNewWorkspace($0, newWindow: true, ctx) }
    }

    private static func reorder(_ invocation: ActionInvocation, forward: Bool, _ ctx: AppActionContext) {
        guard let (group, pane) = group(invocation, ctx) else { return }
        let slots = pane.tabs.map { TabGroupReorder.Slot(group: $0.tabGroup?.rawValue, pinned: $0.pinned) }
        guard let index = TabGroupReorder.targetIndex(of: group.rawValue, forward: forward, in: slots) else {
            return ctx.refuse(RefusalStrings.groupAtEdge)
        }
        let handle = pane.handle
        run("move-tab-group", pane: pane, ctx) { c, t in _ = try await c.moveTabGroup(group, to: handle, index: index, transaction: t) }
    }

    private static func moveToNewWorkspace(_ invocation: ActionInvocation, newWindow: Bool, _ ctx: AppActionContext) {
        guard let (group, pane) = group(invocation, ctx), connection(for: pane, ctx) != nil else { return }
        let windows = ctx.services.windows
        let origin = windows.moveOrigin(of: ctx.services.workspaceID(of: pane))
        Task {
            guard let key = await TabGroupMoves.toNewWorkspace(group, workspaceGroup: nil, index: nil, services: ctx.services,
                                                               transaction: .generate()) else {
                ctx.services.paneController(for: pane)?.resyncStrip()
                return
            }
            windows.placeMoved(key.rawValue, from: origin, preferred: windows.active?.state, newWindow: newWindow)
        }
    }
}
