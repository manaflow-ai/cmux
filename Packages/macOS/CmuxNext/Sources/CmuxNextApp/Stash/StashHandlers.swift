import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextStash

/// Save and Close (Stash, a native OneTab; StashActionCatalog): browser tabs, whole workspaces
/// (every tab and its terminal), a workspace group or a window's workspaces go into one stashed
/// group on this Mac's daemon, and the Stashed Tabs page brings them back. A person's run gets a
/// "Saved to Stashed Tabs" toast whose Undo restores the group at once.
///
/// - Tab rows take browser pages only (a terminal stays open): the tab, or every selected tab
///   when it is one of several selected (`actingTabs`); To the Right and Others follow the
///   strip's order and leave pinned tabs, and Others keeps the selection, as Close Other Tabs
///   does. A tab menu disables them with the reason when no page of the run qualifies.
/// - Workspace rows take the right-clicked workspace, or the sidebar selection it is part of
///   (`WindowMembershipHandlers.rowTargets`); the group row its workspaces; the window row every
///   workspace of the window. The home workspace, incognito workspaces and other machines'
///   workspaces stay; a row whose workspaces are all another machine's leaves the action out, as
///   a tab row on another machine's pane does. They ask first only while a terminal in them runs
///   a program, as a close does.
///   A workspace's remote-terminal tabs let go of their surfaces here (`RemoteTerminalService.stashed`)
///   but, unlike a close (`WorkspaceClose.willClose`), keep their terminals kept on the other
///   machine: Restore reopens each tab on the same terminal from the stash's record. Deleting the
///   stash does not release those terminals yet (#24192).
@MainActor
enum StashHandlers {
    /// The tabs a tab row's Save and Close takes, seen from its tab.
    enum TabScope { case selection, toRight, others }

    static let tabScopes: [ActionID: TabScope] = ["tab.stash": .selection, "tab.stashToRight": .toRight, "tab.stashOthers": .others]
    /// The rows that close whole workspaces (destructive: their terminals end).
    static let workspaceActions: [ActionID] = ["workspace.stash", "workspaceGroup.stash", "window.stash"]

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        let stash = services.historyPage.stash
        for (id, scope) in tabScopes {
            registry.bind(id, unavailable: { stash.unavailableReason() }, run: { invocation in
                guard let tabs = try pages(scope, invocation, context) else { return }
                let ids = tabs.compactMap(\.resourceID)
                guard !ids.isEmpty else { throw ActionFailure.invalidTarget(StashHandlerStrings.noPage) }
                save(invocation, services, workspaces: false, toastIn: services.windows.active?.window) { try await stash.stash(tabs: ids) }
            })
            // A tab menu shows the row disabled with the reason; nothing to look up without a tab target.
            ActionTargetReasons.set(id, in: registry) { invocation in
                guard invocation.target?.kind == .tab, let found = try? pages(scope, invocation, context, quiet: true) else { return nil }
                return found.isEmpty ? StashHandlerStrings.noPage : nil
            }
            ActionTargetVisibility.hide(id, in: registry) { invocation in
                guard invocation.target?.kind == .tab, let id = invocation.target?.id, let (_, pane) = services.locateTab(id) else { return false }
                return !services.machines.daemon(forPane: pane).isLocal
            }
        }
        for id in workspaceActions {
            registry.bind(id, unavailable: { stash.unavailableReason(workspaces: true) }, run: { invocation in
                let (members, name) = try workspaces(id, invocation, context)
                let ids = members.compactMap(\.0.resourceID)
                guard !ids.isEmpty else { throw ActionFailure.invalidTarget(StashHandlerStrings.noWorkspace) }
                // The window that keeps a workspace shows the toast; none when every window closes.
                let window = WorkspaceBulkClose.survivor(closing: members.map(\.0.id), context)
                let remoteTabs = members.flatMap { RemoteTerminalService.remoteTabIDs(in: $0.0) }
                save(invocation, services, workspaces: true, toastIn: window) { [weak services] in
                    let stashID = try await stash.stash(workspaces: ids, name: name)
                    services?.remoteTerminals.stashed(remoteTabs)
                    return stashID
                }
            })
            ActionTargetVisibility.hide(id, in: registry) { invocation in
                guard let ids = try? workspaceIDs(id, invocation, context), !ids.isEmpty else { return false }
                return ids.allSatisfy { services.machines.workspace(id: $0).map { !$0.1.isLocal } ?? false }
            }
        }
        registry.bind("stash.show", unavailable: { stash.unavailableReason() }, run: { invocation in
            _ = try show(services, focus: invocation.allowsViewChange)
        })
        registry.bind("stash.importOneTab", unavailable: { stash.unavailableReason() }, run: { invocation in
            stash.draft(for: try show(services, focus: invocation.allowsViewChange)).open()
        })
    }

    /// Shows the Stashed Tabs page: a person's run as the active window's top page, automation
    /// as a background tab. Returns the page's key (its own search and OneTab paste box).
    @discardableResult
    static func show(_ services: AppServices, focus: Bool) throws -> String {
        let key = focus ? TopPages.show(.page(.stashed), services: services)
            : services.pages.show(.stashed, in: services.windows.active, focus: false)?.key
        guard let key else { throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen) }
        return key
    }

    // MARK: What a run takes

    /// The browser pages `scope` takes from the invocation's tab, in strip order; nil when the
    /// tab did not resolve (the context reported why, unless `quiet`). Pages of an incognito
    /// workspace or another machine are never stashed.
    static func pages(_ scope: TabScope, _ invocation: ActionInvocation, _ context: AppActionContext,
                      quiet: Bool = false) throws -> [TabModel]? {
        let services = context.services
        let found: (TabModel, PaneModel)?
        if quiet {
            found = invocation.target.flatMap { $0.kind == .tab ? services.locateTab($0.id) : nil }
        } else {
            found = context.daemonTab(invocation).map { ($0.tab, $0.pane) }
        }
        guard let (tab, pane) = found else { return nil }
        let daemon = services.machines.daemon(forPane: pane)
        guard daemon.isLocal else { throw ActionFailure.invalidTarget(StashHandlerStrings.otherMachine) }
        guard daemon.store.workspace(containing: pane.handle)?.ephemeral != true else { return [] }
        let controller = services.paneController(for: pane)
        let strip = controller.map { controller in controller.orderedIDs.compactMap { controller.tab($0) } } ?? pane.tabs
        let picked: [TabModel]
        switch scope {
        case .selection:
            picked = controller.map { controller in
                context.actingTabs(invocation, controller, StripTabID(tab.id)).compactMap { controller.tab($0) }
            } ?? [tab]
        case .toRight:
            let index = strip.firstIndex { $0 === tab } ?? strip.count
            picked = strip.dropFirst(index + 1).filter { !$0.pinned }
        case .others:
            picked = controller.map { controller in
                let keep = context.actingTabs(invocation, controller, StripTabID(tab.id))
                return controller.stripModel.closedByCloseOthers(keepingAll: keep).compactMap { controller.tab($0) }
            } ?? strip.filter { $0 !== tab && !$0.pinned }
        }
        return picked.filter(isPage)
    }

    /// A web page Stash keeps: an http(s) browser tab, not a cmux page or an app's tab.
    static func isPage(_ tab: TabModel) -> Bool {
        guard tab.kind == .browser, tab.page == nil, tab.appTab == nil, let url = tab.url else { return false }
        return url.hasPrefix("https://") || url.hasPrefix("http://")
    }

    /// The workspaces a workspace row takes, and the stash's name (a group's), without those
    /// that cannot go: the home workspace, a workspace with no key, an incognito one, and other
    /// machines' (Stash keeps this Mac's).
    static func workspaces(_ id: ActionID, _ invocation: ActionInvocation,
                           _ context: AppActionContext) throws -> ([WorkspaceBulkClose.Member], String?) {
        let windows = context.services.windows
        let ids = try workspaceIDs(id, invocation, context)
        let group = try id == "workspaceGroup.stash" ? context.group(invocation).name : ""
        let members = ids.compactMap { context.services.machines.workspace(id: $0) }.filter { workspace, daemon in
            daemon.isLocal && workspace.key != nil && !HomeRules.isHome(workspace) && !workspace.ephemeral
                && !windows.isIncognito(workspace: workspace.id)
        }
        return (members, group.isEmpty ? nil : group)
    }

    /// Every workspace a workspace row's `id` names, before ``workspaces(_:_:_:)`` leaves out
    /// those that cannot go.
    static func workspaceIDs(_ id: ActionID, _ invocation: ActionInvocation, _ context: AppActionContext) throws -> [String] {
        let windows = context.services.windows
        switch id {
        case "workspaceGroup.stash":
            return try WindowMembershipHandlers.groupMembers(invocation, context)
        case "window.stash":
            // A row's menu takes the window that lists the row.
            let owner = invocation.target.flatMap { $0.kind == .workspace ? windows.registry.value.owner(of: $0.id) : nil }
            return try windows.registry.members(of: owner ?? context.window(invocation).state.id)
        default:
            return try WindowMembershipHandlers.rowTargets(invocation, context).map(\.id)
        }
    }

    /// The question before a person's run of a workspace row: only while a terminal in its
    /// workspaces runs a program (`warn`), as a close asks.
    static func prompt(_ id: ActionID, _ invocation: ActionInvocation, _ context: AppActionContext,
                       warn: Bool) async -> DestructiveConfirmation.Prompt? {
        guard let (members, _) = try? workspaces(id, invocation, context), !members.isEmpty else { return nil }
        return await WorkspaceBulkClose.prompt(members, warn: warn)
    }

    // MARK: Running

    /// Runs `create` as the action's work; a person's run then offers Undo in `window`.
    private static func save(_ invocation: ActionInvocation, _ services: AppServices, workspaces: Bool, toastIn window: NSWindow?,
                             _ create: @escaping @MainActor () async throws -> String) {
        let user = invocation.origin == .user
        report(services.registry, Task { @MainActor [weak services] in
            let stashID: String
            do { stashID = try await create() } catch { return ActionWorkFailure(RefusalStrings.describe(error)) }
            if user, let window, let services { offerUndo(stashID, workspaces: workspaces, in: window, services) }
            return nil
        })
    }

    /// "Saved to Stashed Tabs" with Undo, which restores the whole group where it was.
    private static func offerUndo(_ stashID: String, workspaces: Bool, in window: NSWindow, _ services: AppServices) {
        let toast = CmuxToast(id: "stash.saved.\(stashID)", message: StashHandlerStrings.saved, action: .undo())
        let handle = CmuxToastCenter.shared.show(toast, in: window)
        handle.onAction = { [weak services] in
            guard let services else { return }
            let stash = services.historyPage.stash
            report(services.registry, Task { @MainActor in
                do { try await stash.restoreAll(stashID, workspaces: workspaces) } catch { return ActionWorkFailure(RefusalStrings.describe(error)) }
                return nil
            })
        }
    }

    /// task-owner: a CLI or MCP run awaits `work` (`track`); a palette, menu or toast run nobody
    /// waits on shows its failure as a refusal.
    private static func report(_ registry: ActionRegistry, _ work: ActionWork) {
        if registry.isCapturingWork { return registry.track(work) }
        Task { @MainActor [weak registry] in if let failure = await work.value, !failure.shown { registry?.refuse(failure.message) } }
    }
}

/// The Save and Close handlers' strings (Resources/Stash.xcstrings).
nonisolated enum StashHandlerStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Stash", bundle: .module)
    }

    static var saved: String { t("stash.saved", "Saved to Stashed Tabs") }
    static var noPage: String { t("stash.refusal.noPage", "No web page here to save. Save and Close keeps browser pages.") }
    static var noWorkspace: String {
        t("stash.refusal.noWorkspace", "No workspace here can be saved. Home, incognito and other machines' workspaces stay open.")
    }
    static var otherMachine: String { t("stash.refusal.otherMachine", "Only this Mac's tabs can be saved and closed.") }
}
