public import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextHistory

/// Stash Tab, Stash Tabs to the Right, Stash Other Tabs and Stash Workspace (browser pages
/// only), Show Stashed Tabs and Import from OneTab…. A tab's menu leaves the rows out while its
/// daemon keeps no stashes (or the tab is no daemon tab) and disables them when no browser page
/// of the run qualifies. To the Right and Other follow the strip's order.
extension StashService {
    /// The tabs one Stash action takes, as seen from its tab.
    enum Scope { case tab, toRight, others, workspace }

    static let scopes: [ActionID: Scope] = [
        "tab.stash": .tab, "tab.stashToRight": .toRight, "tab.stashOthers": .others, "workspace.stash": .workspace,
    ]

    /// Binds the Stash actions in `registry`, `host` answering where they act, and starts the
    /// New Tab pages' stash count.
    public func bindActions(into registry: ActionRegistry, host: any StashHost) {
        wireNewTabCount(host: host)
        for (id, scope) in Self.scopes {
            registry.bind(id, invoke: { [weak host] invocation in
                guard let host, let origin = host.stashOrigin(invocation) else { return }
                guard self.serves(origin.daemon) else {
                    return host.registry.refuse(RefusalStrings.needsDaemonCapability(DaemonCapabilities.shared.stash))
                }
                let tabs = Self.pages(scope, origin)
                guard !tabs.isEmpty else { return host.registry.refuse(StashPageModel.noBrowserTab) }
                self.stash(tabs: tabs, workspace: scope == .workspace ? origin.workspace?.resourceID : nil)
            })
            ActionTargetVisibility.hide(id, in: registry) { [weak host] invocation in
                guard let origin = host?.stashOrigin(invocation) else { return true }
                return !self.serves(origin.daemon)
            }
            ActionTargetReasons.set(id, in: registry) { [weak host] invocation in
                guard let origin = host?.stashOrigin(invocation), self.serves(origin.daemon) else { return nil }
                return Self.pages(scope, origin).isEmpty ? StashPageModel.noBrowserTab : nil
            }
        }
        registry.bind("stash.show", unavailable: { self.unavailableReason() }, invoke: { [weak host] _ in host?.showStashedPage() })
        registry.bind("stash.importOneTab", unavailable: { self.unavailableReason() }, invoke: { [weak host] _ in
            if let key = host?.showStashedPage() { self.draft(for: key).open() }
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
