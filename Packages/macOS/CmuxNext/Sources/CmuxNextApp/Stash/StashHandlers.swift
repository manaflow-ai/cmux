import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation

/// Stash Tab, Stash Tabs to the Right, Stash Other Tabs and Stash Workspace
/// (browser pages only), Show Stashed Tabs and Import from OneTab…. A tab's
/// menu leaves the rows out while its daemon keeps no stashes (or the tab is
/// no daemon tab) and disables them when no browser page of the run
/// qualifies. To the Right and Other follow the strip's order.
enum StashHandlers {
    /// The tabs one Stash action takes, as seen from its tab.
    enum Scope { case tab, toRight, others, workspace }

    static let scopes: [ActionID: Scope] = [
        "tab.stash": .tab, "tab.stashToRight": .toRight, "tab.stashOthers": .others, "workspace.stash": .workspace,
    ]

    /// The tab a run acts on: its target, else the focused pane's selected tab.
    struct Origin {
        let tab: TabModel
        let pane: PaneModel
        let workspace: WorkspaceModel?
        let daemon: DaemonService
        /// The pane's tabs in strip order (groups drawn together, pinned first).
        let strip: [TabModel]
    }

    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        let services = ctx.services
        NewTabStashed.wire(services.agentTabs, services: services)
        for (id, scope) in scopes {
            registry.bind(id, invoke: { invocation in
                guard let origin = origin(invocation, ctx) else { return }
                guard services.historyPage.stash.serves(origin.daemon) else {
                    return ctx.refuse(RefusalStrings.needsDaemonCapability(DaemonCapabilities.shared.stash))
                }
                let tabs = pages(scope, origin)
                guard !tabs.isEmpty else { return ctx.refuse(StashAppStrings.noPage) }
                services.historyPage.stash.stash(tabs: tabs, workspace: scope == .workspace ? origin.workspace?.resourceID : nil)
            })
            ActionTargetVisibility.hide(id, in: registry) { [weak services] invocation in
                guard let services, let origin = origin(invocation, ctx) else { return true }
                return !services.historyPage.stash.serves(origin.daemon)
            }
            ActionTargetReasons.set(id, in: registry) { [weak services] invocation in
                guard let services, let origin = origin(invocation, ctx), services.historyPage.stash.serves(origin.daemon) else { return nil }
                return pages(scope, origin).isEmpty ? StashAppStrings.noPage : nil
            }
        }
        let served: @MainActor () -> String? = { [weak services] in
            guard let services, !services.historyPage.stash.serves(services.daemon) else { return nil }
            return services.daemon.missingCapabilityMessage(DaemonCapabilities.shared.stash)
        }
        registry.bind("stash.show", unavailable: served, invoke: { _ in TopPages.show(.page(.stashed), services: services) })
        registry.bind("stash.importOneTab", unavailable: served, invoke: { _ in
            if let key = TopPages.show(.page(.stashed), services: services) { services.historyPage.stash.draft(for: key).open() }
        })
    }

    static func origin(_ invocation: ActionInvocation, _ ctx: AppActionContext) -> Origin? {
        guard let (tab, pane) = ctx.daemonTab(invocation) else { return nil }
        let daemon = ctx.services.machines.daemon(forPane: pane)
        let workspace = daemon.store.workspaces.first { $0.screens.contains { $0.panes.contains { $0 === pane } } }
        let strip = ctx.services.paneController(for: pane).map { controller in controller.orderedIDs.compactMap { controller.tab($0) } }
        return Origin(tab: tab, pane: pane, workspace: workspace, daemon: daemon, strip: strip ?? pane.tabs)
    }

    /// The browser pages `scope` stashes, in pane order: web pages of a workspace that is not
    /// incognito, never another tab that is pinned.
    static func pages(_ scope: Scope, _ origin: Origin) -> [ResourceID] {
        guard origin.workspace?.ephemeral != true else { return [] }
        let tabs = origin.strip, index = tabs.firstIndex { $0 === origin.tab } ?? tabs.count
        let picked: [TabModel] = switch scope {
        case .tab: [origin.tab]
        case .toRight: tabs.dropFirst(index + 1).filter { !$0.pinned }
        case .others: tabs.filter { $0 !== origin.tab && !$0.pinned }
        case .workspace: (origin.workspace?.screens.flatMap(\.panes).flatMap(\.tabs) ?? []).filter { !$0.pinned }
        }
        return picked.filter { tab in
            tab.kind == .browser && tab.page == nil && tab.appTab == nil
                && (tab.url?.hasPrefix("https://") == true || tab.url?.hasPrefix("http://") == true)
        }.compactMap(\.resourceID)
    }
}

enum StashAppStrings {
    static var noPage: String {
        String(localized: "stash.noBrowserTab", defaultValue: "No browser tab here to stash", table: "MiscHandlers", bundle: .module)
    }
}
