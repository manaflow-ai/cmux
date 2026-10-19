import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebar

/// The workspace closes that take several at once: Close Other Workspaces,
/// Close Workspaces Above and Below, Close Others in Group, Close All Workspaces (one window) and
/// Close All Workspaces in All Windows, and Close Workspace on a multi-row selection. One rule for all of them
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
                                  "workspace.closeOthersInGroup", "workspace.closeAll", "workspace.closeAllInAllWindows",
                                  "sidebar.section.closeWorkspaces", "workspaceGroup.closeOthers"]

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
        case "sidebar.section.closeWorkspaces":
            closing = try sectionWorkspaces(invocation, context)
        case "workspaceGroup.closeOthers":
            closing = try otherGroups(invocation, context).1.flatMap(\.workspaces).map(\.id.rawValue)
        case "closeWorkspace":
            // A person's Close Workspace on one of several selected rows closes the selection (`SidebarModel.closeTargets`).
            let target = try context.workspace(invocation).model
            let sidebar = invocation.origin == .user && !invocation.closesRowOnly ? (try? WorkspaceVerbHandlers.sidebar(showing: target, context)) : nil
            closing = sidebar?.model.closeTargets(for: CmuxNextSidebar.WorkspaceID(target.id)).map(\.rawValue) ?? [target.id]
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
        // The store's home workspace never closes (`home_not_closable`, HomeRules), and a
        // workspace with no key cannot (WorkspaceClose): they neither count nor leave.
        let members = closing.compactMap { context.services.machines.workspace(id: $0) }.filter { $0.0.key != nil && !HomeRules.isHome($0.0) }
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
        var groups: [(String?, [String])] = [(nil, names)]
        if id == "workspaceGroup.closeOthers" {
            // Each group closes as Close All Workspaces in Group does (an unpinned group goes);
            // Undo reopens each group's workspaces, then its record.
            let (sidebar, others) = try otherGroups(invocation, context)
            groups = others.map { group in
                (group.id.rawValue, group.workspaces.compactMap { services.machines.workspace(id: $0.id.rawValue)?.0.name })
            }
            for group in others { sidebar.handle(.closeGroup(group.id)) }
        } else if id == "closeWorkspace", let first = members.first {
            // A selection: each group it empties closes as Close Group does (an unpinned group goes, cx-rcby), the
            // other rows as their own close does (InstantClose), asked once (`prompt`) and undone together.
            let sidebar = try WorkspaceVerbHandlers.sidebar(showing: first.0, context)
            let plan = sidebar.model.closePlan(members.map { CmuxNextSidebar.WorkspaceID($0.0.id) })
            let name = { (id: CmuxNextSidebar.WorkspaceID) in services.machines.workspace(id: id.rawValue)?.0.name }
            groups = plan.groups.map { group -> (String?, [String]) in (group.id.rawValue, group.workspaces.compactMap { name($0.id) }) }
                + [(nil, plan.rows.compactMap(name))]
            for group in plan.groups { sidebar.handle(.closeGroup(group.id)) }
            for row in plan.rows { services.registry.perform("closeWorkspace", invocation: ActionInvocation(closingRow: row.rawValue).confirmed()) }
        } else {
            close(members)
        }
        guard invocation.origin == .user, members.count > 1, let window else { return }
        WorkspaceGroupClose.offerUndo("workspaces-closed", closedToast(members.count), groups: groups, after: seen, in: window, services)
    }

    /// The open workspaces a sidebar section lists: its workspace items (Pinned
    /// too), or the window's workspace list for the workspaces section.
    static func sectionWorkspaces(_ invocation: ActionInvocation, _ context: AppActionContext) throws -> [String] {
        let layout = context.services.sidebarLayout
        if let reason = SidebarDocWiring.layoutUnavailableReason(layout) { throw ActionFailure(message: reason) }
        let section = try SidebarSectionResolve.section(invocation.target, in: layout.document)
        switch section.content {
        case .items:
            let refs = WorkspaceLayoutRefs(machines: context.services.machines)
            return section.items.compactMap { refs.workspace(for: $0.ref)?.0.id }
        case .workspaces:
            guard let window = context.activeWindow else { throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen) }
            return window.sidebar.model.selectableWorkspaces.map(\.id.rawValue)
        case .app:
            throw ActionFailure(message: RefusalStrings.sectionTakesNoWorkspaces)
        }
    }

    /// The window sidebar that lists the target group, and that window's other groups.
    static func otherGroups(_ invocation: ActionInvocation, _ context: AppActionContext) throws -> (SidebarBridge, [SidebarGroup]) {
        let group = try context.group(invocation)
        guard let first = try WorkspaceGroupHandlers.members(invocation, context).first else {
            throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn)
        }
        let sidebar = try WorkspaceVerbHandlers.sidebar(showing: first, context)
        let groups = sidebar.model.groups
        guard groups.contains(where: { $0.id.rawValue == group.id.rawValue }) else { throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn) }
        return (sidebar, groups.filter { $0.id.rawValue != group.id.rawValue })
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
        let incognito = members.contains { context.services.windows.isIncognito(workspace: $0.0.id) }
        return await prompt(members, warn: warn, askWithoutUndo: window == nil, incognito: incognito)
    }

    /// Asks when a terminal in `members` runs a program (`warn`), or when two
    /// or more close and nothing can undo it (`askWithoutUndo`).
    static func prompt(_ members: [Member], warn: Bool, askWithoutUndo: Bool = false, incognito: Bool = false,
                       title: String? = nil) async -> DestructiveConfirmation.Prompt? {
        var programs: [String] = []
        if warn { for (workspace, daemon) in members { programs += await DestructiveConfirmation.runningPrograms(in: workspace, on: daemon) } }
        guard let first = members.first, !programs.isEmpty || (askWithoutUndo && members.count > 1) else { return nil }
        let count = String(localized: "confirm.closeWorkspaces.title", defaultValue: "Close \(members.count) workspaces?", table: "Handlers", bundle: .module)
        // Incognito workspaces are never saved: nothing brings them back (WindowRegistry).
        let noUndo = incognito
            ? String(localized: "confirm.closeWorkspaces.noUndoIncognito",
                     defaultValue: "No window stays open to undo this. Incognito workspaces cannot be reopened.", table: "Handlers", bundle: .module)
            : String(localized: "confirm.closeWorkspaces.noUndo",
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
