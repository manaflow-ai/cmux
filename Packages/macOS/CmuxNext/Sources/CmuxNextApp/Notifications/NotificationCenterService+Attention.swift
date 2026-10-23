import AppKit
import CmuxNextAgentPane
import CmuxNextSettings

/// The system banner for a tab an agent marked as needing the person (tab-attention-v1,
/// `cmux attention request`): "Workspace › Tab", "Needs you", the agent's reason. Its Show button
/// (and a click on it) goes to the tab as Search Tabs does; nothing else moves focus. The mark
/// alone never does either. Follows `notifications.*` (desktop mode, muted workspaces, quiet hours,
/// sound) as an agent's notification. Leo, 2026-10-22: "idk where things are man i dont see
/// anything other than the current workspace".
extension NotificationCenterService {
    /// What changed in the marked tabs since the last list: the banners to post (a new mark, or a
    /// new request on a marked tab) and the banner ids to withdraw (a mark that cleared or was
    /// replaced). `previous == nil` is the first list of this launch: marks made before it post
    /// nothing, as notifications that arrived before launch do not.
    nonisolated static func attentionChanges(previous: [AgentPaneAttentionTabs.Item]?, current: [AgentPaneAttentionTabs.Item])
        -> (post: [AgentPaneAttentionTabs.Item], withdraw: [String]) {
        guard let previous else { return ([], []) }
        let before = Set(previous.map(attentionBannerID))
        let now = Set(current.map(attentionBannerID))
        return (current.filter { !before.contains(attentionBannerID($0)) }, previous.map(attentionBannerID).filter { !now.contains($0) })
    }

    /// One banner per request: a new request on the same tab is a new banner.
    nonisolated static func attentionBannerID(_ item: AgentPaneAttentionTabs.Item) -> String {
        "\(attentionBannerPrefix)\(item.atMs).\(item.tabId)"
    }

    /// The tab a Needs you banner names, nil for any other banner.
    nonisolated static func attentionTab(banner: String) -> String? {
        guard banner.hasPrefix(attentionBannerPrefix) else { return nil }
        let rest = banner.dropFirst(attentionBannerPrefix.count)
        guard let dot = rest.firstIndex(of: "."), UInt64(rest[..<dot]) != nil else { return nil }
        let tab = rest[rest.index(after: dot)...]
        return tab.isEmpty ? nil : String(tab)
    }

    nonisolated static let attentionBannerPrefix = "cmux-attention."

    /// The marked tabs changed (``AttentionTabsWatch``): banners for new requests, per policy, and
    /// none left for a mark that cleared.
    func attentionMarksChanged(_ items: [AgentPaneAttentionTabs.Item]) {
        let changes = Self.attentionChanges(previous: attentionSeen, current: items)
        attentionSeen = items
        desktop.withdraw(changes.withdraw)
        guard desktopPostingEnabled else { return }
        for item in changes.post { postAttention(item) }
    }

    private func postAttention(_ item: AgentPaneAttentionTabs.Item) {
        var arrival = NotificationPolicy.Arrival(source: .agent)
        arrival.appActive = NSApp.isActive
        // The row key names the tab's machine (tabs on two machines can share an id).
        if let (machine, tab) = AttentionTabsWatch.split(item.tabId), let services {
            arrival.paneIsViewed = isViewed(tab, onMachine: machine)
            if let daemon = services.machines.daemons.first(where: { $0.machineID == machine }),
               let model = daemon.store.tab(idOrResource: tab), let pane = daemon.store.pane(holding: model),
               let workspace = daemon.store.workspace(containing: pane.handle) {
                arrival.workspaceMuted = preferences.mutedWorkspaces.contains(workspace.id)
            }
        }
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        arrival.minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let decision = NotificationPolicy(prefs: preferences).decide(arrival)
        note("attention \(item.tabId) \(decision)")
        guard decision.desktop else { return }
        let content = bannerFormatter.content(headline: AttentionBannerStrings.needsYou, posterSubtitle: nil, body: item.reason,
                                              workspace: item.workspaceTitle, tab: item.tabTitle, host: nil)
        desktop.post(id: Self.attentionBannerID(item), title: content.title, subtitle: content.subtitle, body: content.body,
                     surface: nil, workspace: nil, defaultSound: decision.sound == "default", category: DesktopNotifier.attentionCategory)
        if let sound = decision.sound, sound != "default" { NotificationSounds.play(sound) }
    }

    /// Tab `tabID` of machine `machine` is the focused content of the key window while cmux is
    /// active (``isViewed(_:)`` on that machine only).
    private func isViewed(_ tabID: String, onMachine machine: String) -> Bool {
        guard let services, NSApp.isActive else { return false }
        return services.windows.controllers.contains { controller in
            controller.focus.state.windowKey && Self.contentTab(controller.focus.state.resolved) == tabID
                && controller.content?.daemon.machineID == machine
        }
    }

    /// A Needs you banner's Show (or click): the tab, as a user's jump (``AgentPaneAttentionTabs/open(_:)``).
    func showAttention(banner: String) -> Bool {
        guard let tab = Self.attentionTab(banner: banner) else { return false }
        if !AgentPaneAttentionTabs.shared.open(tab) { note("attention banner \(banner): the mark is gone") }
        return true
    }
}

/// Text of the Needs you banner. Keys live in Resources/Localizable.xcstrings.
struct AttentionBannerStrings {
    static var needsYou: String { String(localized: "notifications.attention.needsYou", defaultValue: "Needs you", bundle: .module) }
    static var show: String { String(localized: "notifications.attention.show", defaultValue: "Show", bundle: .module) }
}
