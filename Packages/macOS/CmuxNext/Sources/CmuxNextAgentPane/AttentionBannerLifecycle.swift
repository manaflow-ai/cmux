import CmuxNextWindowRules

/// Identity and set reconciliation for needs-you requests, independent of the system notifier. The rules
/// are cmux-window-rules `desktop_attention` (AttentionBannerLifecycle+Wire); a rule that does not answer
/// posts, withdraws and names nothing.
public struct AttentionBannerLifecycle {
    public init() {}
    /// What changed in the marked tabs since the last list: the banners to post (a new mark, or a
    /// new request on a marked tab) and the banner ids to withdraw (a mark that cleared or was
    /// replaced). `previous == nil` is the first list of this launch: marks made before it post
    /// nothing, as notifications that arrived before launch do not.
    public nonisolated static func attentionChanges(previous: [AgentPaneAttentionTabs.Item]?, current: [AgentPaneAttentionTabs.Item])
        -> (post: [AgentPaneAttentionTabs.Item], withdraw: [String]) {
        guard let changes = changes(previous: previous, current: current, eligible: nil) else { return ([], []) }
        return (items(changes.post, of: current), changes.withdraw)
    }

    /// The watch has already classified current-launch changes per machine. Its eligible set
    /// may include a request seen earlier while the tree was unready, so don't diff it away.
    public nonisolated static func posts(previous: [AgentPaneAttentionTabs.Item]?, current: [AgentPaneAttentionTabs.Item],
                                         eligibleRequests: Set<String>?) -> [AgentPaneAttentionTabs.Item] {
        guard let changes = changes(previous: previous, current: current, eligible: eligibleRequests.map { Array($0) }) else { return [] }
        return items(changes.posts, of: current)
    }

    /// One banner per request: a new request on the same tab is a new banner.
    public nonisolated static func attentionBannerID(_ item: AgentPaneAttentionTabs.Item) -> String {
        "\(attentionBannerPrefix)\(item.tabId)"
    }

    /// The tab a Needs you banner names, nil for any other banner.
    public nonisolated static func attentionTab(banner: String) -> String? {
        WindowRules().call("window_notifications_desktop_attention_tab", BannerAsk(banner: banner), as: TabReply.self)?.tab
    }

    public nonisolated static let attentionBannerPrefix = "cmux-attention."

    /// Snapshot IDs from Notification Center minus requests this launch posted. Call this after
    /// the center answers, using the latest set, so a concurrent new banner is never withdrawn.
    public nonisolated static func staleBannerIDs(_ retained: [String], currentLaunch: Set<String>) -> [String] {
        WindowRules().call("window_notifications_desktop_attention_stale",
                           RetainedAsk(retained: retained, currentLaunch: Array(currentLaunch)), as: StaleReply.self)?.stale ?? []
    }
}
