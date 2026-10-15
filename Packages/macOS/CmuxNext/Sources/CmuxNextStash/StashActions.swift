public import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextHistory

/// Stash Tab, Stash Tabs to the Right, Stash Other Tabs and Stash Workspace (browser pages
/// only), Show Stashed Tabs and Import from OneTab…. A tab's menu leaves the rows out while its
/// daemon keeps no stashes (or the tab is no daemon tab) and disables them when no browser page
/// of the run qualifies. To the Right and Other follow the strip's order.
public enum StashActions {
    /// The tabs one Stash action takes, as seen from its tab.
    enum Scope { case tab, toRight, others, workspace }

    static let scopes: [ActionID: Scope] = [
        "tab.stash": .tab, "tab.stashToRight": .toRight, "tab.stashOthers": .others, "workspace.stash": .workspace,
    ]

    /// Binds the Stash actions in `registry` to `stash`, whose host answers where they act, and
    /// starts the New Tab pages' stash count.
    public static func bind(into registry: ActionRegistry, stash: StashService, host: any StashHost) {
        StashNewTabCount.wire(stash, host: host)
        for (id, scope) in scopes {
            registry.bind(id, invoke: { [weak host] invocation in
                guard let host, let origin = host.stashOrigin(invocation) else { return }
                guard stash.serves(origin.daemon) else {
                    return host.registry.refuse(RefusalStrings.needsDaemonCapability(DaemonCapabilities.shared.stash))
                }
                let tabs = pages(scope, origin)
                guard !tabs.isEmpty else { return host.registry.refuse(StashStrings.noBrowserTab) }
                stash.stash(tabs: tabs, workspace: scope == .workspace ? origin.workspace?.resourceID : nil)
            })
            ActionTargetVisibility.hide(id, in: registry) { [weak host] invocation in
                guard let origin = host?.stashOrigin(invocation) else { return true }
                return !stash.serves(origin.daemon)
            }
            ActionTargetReasons.set(id, in: registry) { [weak host] invocation in
                guard let origin = host?.stashOrigin(invocation), stash.serves(origin.daemon) else { return nil }
                return pages(scope, origin).isEmpty ? StashStrings.noBrowserTab : nil
            }
        }
        registry.bind("stash.show", unavailable: { stash.unavailableReason() }, invoke: { [weak host] _ in host?.showStashedPage() })
        registry.bind("stash.importOneTab", unavailable: { stash.unavailableReason() }, invoke: { [weak host] _ in
            if let key = host?.showStashedPage() { stash.draft(for: key).open() }
        })
    }

    /// The browser pages `scope` stashes, in strip order: web pages of a workspace that is not
    /// incognito, never another tab that is pinned.
    static func pages(_ scope: Scope, _ origin: StashOrigin) -> [ResourceID] {
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
