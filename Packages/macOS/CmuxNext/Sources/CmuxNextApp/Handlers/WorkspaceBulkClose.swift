import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebar

/// The workspace closes that take several at once: Close Other Workspaces,
/// Close Workspaces Above and Below, Close Others in Group, Close All Workspaces (one window) and
/// Close All Workspaces in All Windows. One rule for all of them
/// (RECOVERABLE-BY-DEFAULT, Lawrence 2026-10-07): they run at once, and a
/// person's gesture that closes two or more gets "Closed N workspaces"
/// with Undo in a window that stays open (`WorkspaceGroupClose.reopen`). They ask first
/// (`DestructiveConfirmation`) when a terminal in them runs a program and
/// `app.warnBeforeClosingTab` is on, or when two or more close and no window
/// stays open to show the undo (the window closes with its last workspace,
/// WindowRegistry); Reopen Closed Workspace and History still have them.
@MainActor
enum WorkspaceBulkClose {
    typealias Member = (WorkspaceModel, DaemonService)
    static let ids: [ActionID] = ["palette.closeOtherWorkspaces", "palette.closeWorkspacesBelow", "palette.closeWorkspacesAbove",
                                  "workspace.closeOthersInGroup", "workspace.closeAll", "workspace.closeAllInAllWindows"]

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        for id in ids { registry.bind(id, run: { invocation in try close(id, invocation, context) }) }
    }

    /// What a run of `id` closes, and the window that stays open to show its
    /// undo toast (nil when none does).
    static func plan(_ id: ActionID, _ invocation: ActionInvocation, _ context: AppActionContext) throws -> ([Member], NSWindow?) {
        let windows = context.services.windows
        let closing: [String]
        switch id {
        case "workspace.closeAll":
            // A row's menu closes the rows of the window that lists it.
            let owner = invocation.target.flatMap { $0.kind == .workspace ? windows.registry.value.owner(of: $0.id) : nil }
            closing = try windows.registry.members(of: owner ?? context.window(invocation).state.id)
        case "workspace.closeAllInAllWindows":
            closing = windows.controllers.flatMap { windows.registry.members(of: $0.state.id) }
        case "workspace.closeOthersInGroup":
            let workspace = try context.workspace(invocation).model
            guard let group = try WorkspaceVerbHandlers.group(of: workspace, context) else { throw ActionFailure.invalidTarget(RefusalStrings.workspaceNotInGroup) }
            closing = group.workspaces.map(\.id.rawValue).filter { $0 != workspace.id }
        default:
            // Sidebar order of the window that lists the target, every machine's rows.
            let target = try context.workspace(invocation).model
            let owner = windows.registry.value.owner(of: target.id).flatMap(windows.controller(for:)) ?? context.activeWindow
            let order = owner?.sidebar.model.selectableWorkspaces.map(\.id.rawValue) ?? context.sidebarOrder.map(\.id)
            guard let index = order.firstIndex(of: target.id) else { throw ActionFailure.invalidTarget(RefusalStrings.workspaceNotInSidebar) }
            closing = id == "palette.closeOtherWorkspaces" ? order.filter { $0 != target.id }
                : id == "palette.closeWorkspacesBelow" ? Array(order[(index + 1)...]) : Array(order[..<index])
        }
        // A workspace with no key cannot close (WorkspaceClose); it neither counts nor leaves.
        let members = closing.compactMap { context.services.machines.workspace(id: $0) }.filter { $0.0.key != nil }
        return (members, survivor(closing: members.map(\.0.id), context))
    }

    /// An open window that keeps a workspace after `closing` closes (the
    /// active one first): where the undo toast shows. Nil when every window closes.
    static func survivor(closing: [String], _ context: AppActionContext) -> NSWindow? {
        let windows = context.services.windows
        let gone = Set(closing)
        let stays = ([context.activeWindow].compactMap { $0 } + windows.controllers).first { controller in
            !windows.registry.members(of: controller.state.id).allSatisfy(gone.contains)
        }
        return stays?.window
    }

    static func close(_ id: ActionID, _ invocation: ActionInvocation, _ context: AppActionContext) throws {
        let (members, window) = try plan(id, invocation, context)
        let services = context.services
        let names = members.map { $0.0.name }
        let seen = Set(DaemonClosedHistory.entries([.workspace], in: services).map(\.item.id))
        close(members)
        guard invocation.origin == .user, members.count > 1, let window else { return }
        WorkspaceGroupClose.offerUndo("workspaces-closed", closedToast(members.count), group: nil, names: names, after: seen, in: window, services)
    }

    /// The one close path for each workspace, on the daemon that owns it.
    static func close(_ members: [Member]) {
        for (workspace, daemon) in members {
            guard let key = workspace.key else { continue }
            let terminals = WorkspaceClose.closing(workspace, on: daemon)
            daemon.send("close-workspace") { try await WorkspaceClose.close(key, terminals: terminals, on: $0) }
        }
    }

    /// The question before a person's run of `id`, or nil to close at once.
    static func prompt(_ id: ActionID, _ invocation: ActionInvocation, _ context: AppActionContext, warn: Bool) async -> DestructiveConfirmation.Prompt? {
        guard let (members, window) = try? plan(id, invocation, context) else { return nil }
        return await prompt(members, warn: warn, askWithoutUndo: window == nil)
    }

    /// Asks when a terminal in `members` runs a program (`warn`), or when two
    /// or more close and nothing can undo it (`askWithoutUndo`).
    static func prompt(_ members: [Member], warn: Bool, askWithoutUndo: Bool = false, title: String? = nil) async -> DestructiveConfirmation.Prompt? {
        var programs: [String] = []
        if warn { for (workspace, daemon) in members { programs += await DestructiveConfirmation.runningPrograms(in: workspace, on: daemon) } }
        guard let first = members.first, !programs.isEmpty || (askWithoutUndo && members.count > 1) else { return nil }
        let count = String(localized: "confirm.closeWorkspaces.title", defaultValue: "Close \(members.count) workspaces?", table: "Handlers", bundle: .module)
        let noUndo = String(localized: "confirm.closeWorkspaces.noUndo",
                            defaultValue: "No window stays open to undo this. Reopen Closed Workspace and History bring them back.",
                            table: "Handlers", bundle: .module)
        return DestructiveConfirmation.Prompt(
            title: title ?? (members.count == 1 ? ConfirmationStrings.closeWorkspaceTitle(first.0.displayName) : count),
            body: programs.isEmpty ? noUndo : ConfirmationStrings.stillRunning(Set(programs).sorted().joined(separator: ", ")),
            button: ConfirmationStrings.close, suppresses: programs.isEmpty ? nil : CmuxConfigSnapshot.warnBeforeClosingTabPath)
    }

    static func closedToast(_ count: Int) -> String {
        String(localized: "workspaces.closedToast", defaultValue: "Closed \(count) workspaces", table: "Handlers", bundle: .module)
    }
}
