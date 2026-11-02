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
                                  "workspace.closeOthersInGroup", "workspace.closeAll", "workspace.closeAllInAllWindows",
                                  "sidebar.section.closeWorkspaces", "workspaceGroup.closeOthers"]

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        for id in ids { registry.bind(id, run: { invocation in try close(id, invocation, context) }) }
        // On the bottom or top row, with only Home left, or alone in its group the close has
        // nothing to close: the row is disabled with the reason and every run is refused with it.
        for (id, none) in nothingToClose {
            context.setTargetReason(id) { invocation in
                ((try? plan(id, invocation, context))?.0.isEmpty ?? false) ? none() : nil
            }
        }
    }

    /// The closes that can find nothing to close, and what they say then.
    static let nothingToClose: [(ActionID, @MainActor () -> String)] = [
        ("palette.closeOtherWorkspaces", { RefusalStrings.noOtherWorkspacesToClose }),
        ("palette.closeWorkspacesBelow", { RefusalStrings.noWorkspacesBelowToClose }),
        ("palette.closeWorkspacesAbove", { RefusalStrings.noWorkspacesAboveToClose }),
        ("workspace.closeOthersInGroup", { RefusalStrings.noOtherWorkspacesInGroupToClose }),
    ]

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
        case "workspace.closeOthersInGroup":
            let workspace = try context.workspace(invocation).model
            guard let group = try WorkspaceVerbHandlers.group(of: workspace, context) else { throw ActionFailure.invalidTarget(RefusalStrings.workspaceNotInGroup) }
            closing = group.workspaces.map(\.id.rawValue).filter { $0 != workspace.id }
        default:
            // Sidebar order of the window that lists the target, every machine's rows.
            let target = try context.workspace(invocation).model
            let owner = windows.registry.value.owner(of: target.id).flatMap(windows.controller(for:)) ?? context.activeWindow
            let order = owner?.sidebar.model.selectableWorkspaces.map(\.id.rawValue) ?? context.sidebarOrder.map(\.id)
            guard order.contains(target.id) else { throw ActionFailure.invalidTarget(RefusalStrings.workspaceNotInSidebar) }
            // A person's run on one of several selected rows keeps the whole selection, as Chrome's
            // Close Other Tabs and Close Tabs Below do: the rows outside it, below its last, above its first.
            let kept = try WindowMembershipHandlers.rowTargets(invocation, context).map(\.id)
            closing = keeping(Set(kept), id: id, order: order)
        }
        // The store's home workspace never closes (`home_not_closable`, HomeRules), and a
        // workspace with no key cannot (WorkspaceClose): they neither count nor leave.
        let members = closing.compactMap { context.services.machines.workspace(id: $0) }.filter { $0.0.key != nil && !HomeRules.isHome($0.0) }
        return (members, survivor(closing: members.map(\.0.id), context))
    }

    /// What Close Other Workspaces, Close Workspaces Below and Close Workspaces Above (`id`)
    /// close of `order` (a sidebar's rows) around the rows `kept`: every other row, the rows
    /// below the last kept one, or the rows above the first.
    nonisolated static func keeping(_ kept: Set<String>, id: ActionID, order: [String]) -> [String] {
        guard let first = order.firstIndex(where: kept.contains), let last = order.lastIndex(where: kept.contains) else { return [] }
        switch id {
        case "palette.closeOtherWorkspaces": return order.filter { !kept.contains($0) }
        case "palette.closeWorkspacesBelow": return Array(order[(last + 1)...])
        default: return Array(order[..<first])
        }
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
        if members.isEmpty, let none = nothingToClose.first(where: { $0.0 == id })?.1 { throw ActionFailure.invalidTarget(none()) }
        let services = context.services
        let names = members.map { $0.0.name }
        let seen = Set(DaemonClosedHistory.entries([.workspace], in: services).map(\.item.id))
        var groups: [(String?, [String])] = [(nil, names)]
        if id == "workspaceGroup.closeOthers" {
            // Each group closes as Close Workspaces in Group does (an unpinned group goes);
            // Undo reopens each group's workspaces, then its record.
            let (sidebar, others) = try otherGroups(invocation, context)
            groups = others.map { group in
                (group.id.rawValue, group.workspaces.compactMap { services.machines.workspace(id: $0.id.rawValue)?.0.name })
            }
            for group in others { sidebar.handle(.closeGroup(group.id)) }
        } else {
            WorkspaceClose.close(members)
        }
        guard invocation.origin == .user, members.count > 1, let window else { return }
        WorkspaceGroupClose.offerUndo("workspaces-closed", closedToast(members.count), groups: groups, after: seen, in: window, services)
    }

    /// The open workspaces a sidebar section lists: its workspace items (Pinned
    /// too) the active window draws (not another window's, which it leaves
    /// out: `SidebarRows.visibleLayout`), or the window's workspace list for
    /// the workspaces section.
    static func sectionWorkspaces(_ invocation: ActionInvocation, _ context: AppActionContext) throws -> [String] {
        let layout = context.services.sidebarLayout
        if let reason = context.services.sidebarDoc.layoutUnavailableReason(layout) { throw ActionFailure(message: reason) }
        let section = try SidebarSectionResolve.section(invocation.target, in: layout.document)
        switch section.content {
        case .items:
            let refs = WorkspaceLayoutRefs(machines: context.services.machines)
            let registry = context.services.windows.registry.value, window = context.activeWindow?.state.id
            return section.items.filter { item in
                window.map { !refs.ownedElsewhere(item.ref.value, window: $0, registry: registry) } ?? true
            }.compactMap { refs.workspace(for: $0.ref)?.0.id }
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
        let groups = sidebar.model.sections.flatMap(\.nodes).compactMap { node -> SidebarGroup? in
            if case .group(let listed) = node { return listed }
            return nil
        }
        guard groups.contains(where: { $0.id.rawValue == group.id.rawValue }) else { throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn) }
        return (sidebar, groups.filter { $0.id.rawValue != group.id.rawValue })
    }

    /// The question before a person's run of `id`, or nil to close at once.
    static func prompt(_ id: ActionID, _ invocation: ActionInvocation, _ context: AppActionContext, warn: Bool) async -> DestructiveConfirmation.Prompt? {
        guard let (members, window) = try? plan(id, invocation, context) else { return nil }
        let incognito = members.contains { context.services.windows.isIncognito(workspace: $0.0.id) }
        return await prompt(members, warn: warn, askWithoutUndo: window == nil, incognito: incognito)
    }

    /// Whether `prompt` will likely ask about `members`, read from the store without the daemon: two
    /// or more close with nothing to undo it, or (`warn`) one has a live terminal on a connected
    /// machine that is not known to sit at its shell prompt (OSC 133, `TabModel.promptSinceMs`).
    /// True: the rows stay until the answer. False: they leave at the press, and the terminals are
    /// still asked behind them (a prompt can show while ssh or a nested shell runs, `WorkspaceCloseFlow`).
    static func mayAsk(_ members: [Member], warn: Bool, askWithoutUndo: Bool = false) -> Bool {
        if askWithoutUndo, members.count > 1 { return true }
        return warn && members.contains { workspace, daemon in
            daemon.isLive && workspace.screens.flatMap(\.panes).flatMap(\.tabs).contains(where: mayRunProgram)
        }
    }

    /// A live terminal whose shell may be running a program: a command runs, or no prompt was seen.
    static func mayRunProgram(_ tab: TabModel) -> Bool {
        tab.kind == .pty && !tab.dead && (tab.commandSinceMs != nil || tab.promptSinceMs == nil)
    }

    /// Asks when a terminal in `members` runs a program (`warn`), or when two
    /// or more close and nothing can undo it (`askWithoutUndo`).
    static func prompt(_ members: [Member], warn: Bool, askWithoutUndo: Bool = false, incognito: Bool = false,
                       title: String? = nil) async -> DestructiveConfirmation.Prompt? {
        var programs: [String] = []
        // Every workspace's terminals are asked at once: each answers within its own short deadline.
        // task-owner: one process-info lookup per workspace, all awaited right here.
        let lookups = (warn ? members : []).map { member in Task { @MainActor in await DestructiveConfirmation.runningPrograms(in: member.0, on: member.1) } }
        for lookup in lookups { programs += await lookup.value }
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
