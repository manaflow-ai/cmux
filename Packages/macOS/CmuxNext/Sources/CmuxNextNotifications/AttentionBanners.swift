import AppKit
package import CmuxNextAgentPane
package import CmuxNextDaemon
package import CmuxNextDaemonService
package import CmuxNextFeed
package import CmuxNextSettings
import Foundation

/// What ``AttentionBanners`` reads from the app's notification service: the `notifications.*`
/// preferences, the shared sound gate, the system notifier, and the facts about a tab that only
/// the app's windows and machines know.
@MainActor
package protocol AttentionBannerHost: AnyObject {
    var preferences: NotificationPreferences { get }
    var soundGate: NotificationSoundGate { get }
    var bannerFormatter: NotificationBannerFormatter { get }
    var desktop: DesktopNotifier { get }
    var desktopPostingEnabled: Bool { get }
    /// The marked-tab list every agent page and the palette share; nil before the app's services start.
    var attentionTabs: AgentPaneAttentionTabs? { get }
    /// Every connected machine (empty before the app's services start).
    var attentionDaemons: [DaemonService] { get }
    /// Tab `tab` of machine `machine` is the focused content of the key window while cmux is active.
    func isViewed(_ tab: String, onMachine machine: String) -> Bool
    /// Seconds since a key last reached tab `tabID` of machine `machine` (Quiet After Typing), nil if never.
    func typedAgo(tabID: String, onMachine machine: String) -> Double?
    /// Whether `workspace` is muted, and the key its sound rule is read under, on `machine`.
    func notificationKeys(of workspace: WorkspaceModel, machine: String?) -> (muted: Bool, soundRule: String)
    /// Whether `workspace` shows in an incognito window.
    func isIncognito(_ workspace: WorkspaceModel) -> Bool
    /// One line of the `debug.notifications` log.
    func note(_ line: String)
}

/// The system banner for a tab an agent marked as needing the person (tab-attention-v1,
/// `cmux attention request`): "Workspace › Tab", "Needs you", the agent's reason. Its Show button
/// (and a click on it) goes to the tab as Search Tabs does; nothing else moves focus. The mark
/// alone never does either. Follows `notifications.*` (desktop mode, muted workspaces, quiet hours,
/// sound) as an agent's notification. Leo, 2026-10-22: "idk where things are man i dont see
/// anything other than the current workspace".
@MainActor
package final class AttentionBanners {
    /// The notification service that owns this (and so outlives it).
    private weak var host: (any AttentionBannerHost)?
    /// The marked tabs at the last change; nil before the first list.
    package private(set) var seen: [AgentPaneAttentionTabs.Item]?
    /// The Needs you banners this launch posted and has not withdrawn: only these may Show.
    package var posted: Set<String> = []
    /// The launch reconciliation of banners an earlier launch left behind.
    private var reconcile: Task<Void, Never>?

    package init(host: any AttentionBannerHost) {
        self.host = host
    }

    // The task is a Sendable stored value, so cancelling it needs no main-actor hop.
    nonisolated deinit { reconcile?.cancel() }

    /// The marked tabs changed (``AttentionTabsWatch``): banners for new requests, per policy, and
    /// none left for a mark that cleared.
    package func marksChanged(_ items: [AgentPaneAttentionTabs.Item], eligibleRequests: Set<String>? = nil) {
        guard let host else { return }
        let firstList = seen == nil
        let changes = AttentionBannerLifecycle.attentionChanges(previous: seen, current: items)
        let posts = AttentionBannerLifecycle.posts(previous: seen, current: items, eligibleRequests: eligibleRequests)
        seen = items
        let desktop = host.desktop
        desktop.withdraw(changes.withdraw)
        posted.subtract(changes.withdraw)
        if firstList {
            // A prior launch may have left a delivered attention banner behind after its mark
            // cleared. Reconcile the center once the first live list is available.
            // task-owner: AttentionBanners.reconcile; one snapshot completes it, cancelled in deinit, and the owner is weak
            reconcile = Task { @MainActor [weak self, desktop] in
                let retained = await desktop.attentionBannerIDs()
                guard let self, !Task.isCancelled else { return }
                // Read the current set after the await: a new request may have posted while
                // Notification Center answered. Only banners from a prior launch are removed.
                desktop.withdraw(AttentionBannerLifecycle.staleBannerIDs(retained, currentLaunch: self.posted))
            }
        }
        guard host.desktopPostingEnabled else { return }
        for item in posts { post(item) }
    }

    /// The policy's decision for `item`'s banner, its sound through the shared cooldown; nil once the host is gone.
    package func decision(_ item: AgentPaneAttentionTabs.Item) -> NotificationPolicy.Decision? {
        guard let host else { return nil }
        var decision = NotificationPolicy(prefs: host.preferences).decide(arrival(item))
        host.soundGate.admit(&decision, cooldownSeconds: host.preferences.sounds.cooldownSeconds)
        return decision
    }

    /// A request key resolves only while that same owner-issued request is still live.
    private func live(_ item: AgentPaneAttentionTabs.Item) -> (DaemonService, TabModel)? {
        guard let host,
              let located = AttentionTabsWatch.locate(item.tabId, in: host.attentionDaemons, machineID: { $0.machineID }),
              let tab = located.daemon.store.tab(idOrResource: located.tab),
              tab.attention?.requestID == located.requestID else { return nil }
        return (located.daemon, tab)
    }

    private func post(_ item: AgentPaneAttentionTabs.Item) {
        guard let host, let (daemon, tab) = live(item) else { return }
        // An incognito window's tab names nothing of itself in Notification Center (DesktopNotifier+Incognito).
        let incognito = daemon.store.pane(holding: tab).flatMap { daemon.store.workspace(containing: $0.handle) }
            .map { host.isIncognito($0) } ?? false
        guard let decision = self.decision(item) else { return }
        host.note("attention \(item.tabId) \(decision)")
        if decision.desktop {
            posted.insert(AttentionBannerLifecycle.attentionBannerID(item))
            let content = host.bannerFormatter.content(headline: String(localized: "notifications.attention.needsYou", defaultValue: "Needs you", bundle: .module),
                                                       posterSubtitle: nil, body: item.reason, workspace: item.workspaceTitle, tab: item.tabTitle, host: nil)
            host.desktop.post(id: AttentionBannerLifecycle.attentionBannerID(item), title: content.title, subtitle: content.subtitle, body: content.body,
                              surface: nil, workspace: nil, defaultSound: decision.sound == "default", category: DesktopNotifier.attentionCategory,
                              incognito: incognito)
        }
        if let sound = decision.sound, sound != "default" || !decision.desktop {
            host.soundGate.player.play(sound, volume: decision.soundVolume, banner: decision.desktop)
        }
    }

    /// What the policy reads for `item`'s banner: whether its pane is viewed and its workspace
    /// muted, both for the tab on the machine its row key names.
    package func arrival(_ item: AgentPaneAttentionTabs.Item) -> NotificationPolicy.Arrival {
        var arrival = NotificationPolicy.Arrival(source: .agent)
        arrival.appActive = NSApp.isActive
        // The row key names the tab's machine (tabs on two machines can share an id).
        if let host, let (daemon, model) = live(item) {
            let tab = model.id
            arrival.paneIsViewed = host.isViewed(tab, onMachine: daemon.machineID)
            arrival.typedAgo = host.typedAgo(tabID: tab, onMachine: daemon.machineID)
            if let pane = daemon.store.pane(holding: model),
               let workspace = daemon.store.workspace(containing: pane.handle) {
                let keys = host.notificationKeys(of: workspace, machine: daemon.machineID)
                arrival.workspaceMuted = keys.muted
                (arrival.soundEvent, arrival.soundScope) = host.soundGate.classify(
                    level: "warning", source: .agent, agent: model.agentSession?.harness ?? model.agent?.agent, workspace: keys.soundRule)
            }
        }
        if arrival.soundEvent == nil { arrival.soundEvent = .needsInput }
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        arrival.minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return arrival
    }

    /// A Needs you banner's Show (or click): the tab, as a user's jump (``AgentPaneAttentionTabs/open(_:)``),
    /// only for a banner this launch posted whose request is still the tab's live mark. A banner
    /// from an earlier launch, or one a newer request on the tab replaced, opens nothing.
    package func show(banner: String) -> Bool {
        guard let tab = AttentionBannerLifecycle.attentionTab(banner: banner) else { return false }
        guard let shared = host?.attentionTabs else { return true }
        guard posted.contains(banner), shared.items.contains(where: { AttentionBannerLifecycle.attentionBannerID($0) == banner }) else {
            host?.note("attention banner \(banner): its request is gone")
            return true
        }
        if !shared.open(tab) { host?.note("attention banner \(banner): the tab is gone") }
        return true
    }
}
