import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation

/// Stash Tab, Stash Tabs to the Right, Stash Other Tabs and Stash Workspace
/// (browser pages only), Show Stashed Tabs and Import from OneTab…. A tab's
/// menu leaves the rows out while its daemon keeps no stashes and disables
/// them when no browser page of the run qualifies.
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
    }

    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        let services = ctx.services
        NewTabStashed.wire(services.agentTabs, services: services)
        for (id, scope) in scopes {
            registry.bind(id, invoke: { invocation in
                guard let origin = origin(invocation, services) else { return ctx.refuse(RefusalStrings.focusedPaneHasNoTab) }
                guard services.historyPage.stash.serves(origin.daemon) else {
                    return ctx.refuse(RefusalStrings.needsDaemonCapability(DaemonCapabilities.shared.stash))
                }
                let tabs = pages(scope, origin)
                guard !tabs.isEmpty else { return ctx.refuse(StashAppStrings.noPage) }
                services.historyPage.stash.stash(tabs: tabs, workspace: scope == .workspace ? origin.workspace?.resourceID : nil)
            })
            ActionTargetVisibility.hide(id, in: registry) { [weak services] invocation in
                guard let services, let origin = origin(invocation, services) else { return false }
                return !services.historyPage.stash.serves(origin.daemon)
            }
            ActionTargetReasons.set(id, in: registry) { [weak services] invocation in
                guard let services, let origin = origin(invocation, services), services.historyPage.stash.serves(origin.daemon) else { return nil }
                return pages(scope, origin).isEmpty ? StashAppStrings.noPage : nil
            }
        }
        let served: @MainActor () -> String? = { [weak services] in
            guard let services, !services.historyPage.stash.serves(services.daemon) else { return nil }
            return services.daemon.missingCapabilityMessage(DaemonCapabilities.shared.stash)
        }
        registry.bind("stash.show", unavailable: served, invoke: { _ in TopPages.show(.page(.stashed), services: services) })
        registry.bind("stash.importOneTab", unavailable: served, invoke: { _ in
            services.historyPage.stash.model.showImport()
            TopPages.show(.page(.stashed), services: services)
        })
    }

    static func origin(_ invocation: ActionInvocation, _ services: AppServices) -> Origin? {
        let found: (TabModel, PaneModel)?
        if let ref = invocation.target, ref.kind == .tab {
            found = services.locateTab(ref.id)
        } else if let pane = services.windows.active?.focusedPane, let tab = pane.selectedTab {
            found = (tab, pane.pane)
        } else {
            found = nil
        }
        guard let (tab, pane) = found else { return nil }
        let daemon = services.machines.daemon(forTab: tab)
        let workspace = daemon.store.workspaces.first { $0.screens.contains { $0.panes.contains { $0 === pane } } }
        return Origin(tab: tab, pane: pane, workspace: workspace, daemon: daemon)
    }

    /// The browser pages `scope` stashes, in pane order: web pages of a workspace that is not
    /// incognito, never another tab that is pinned.
    static func pages(_ scope: Scope, _ origin: Origin) -> [ResourceID] {
        guard origin.workspace?.ephemeral != true else { return [] }
        let tabs = origin.pane.tabs, index = tabs.firstIndex { $0 === origin.tab } ?? tabs.count
        let picked: [TabModel] = switch scope {
        case .tab: [origin.tab]
        case .toRight: tabs.dropFirst(index + 1).filter { !$0.pinned }
        case .others: tabs.filter { $0 !== origin.tab && !$0.pinned }
        case .workspace: (origin.workspace?.screens.flatMap(\.panes).flatMap(\.tabs) ?? []).filter { !$0.pinned }
        }
        return picked.filter { tab in
            tab.kind == .browser && tab.page == nil && (tab.url?.hasPrefix("https://") == true || tab.url?.hasPrefix("http://") == true)
        }.compactMap(\.resourceID)
    }
}

enum StashAppStrings {
    static var noPage: String {
        String(localized: "stash.noBrowserTab", defaultValue: "No browser tab here to stash", table: "MiscHandlers", bundle: .module)
    }
}
