/// Identity and set reconciliation for needs-you requests, independent of the system notifier.
/// The rules are cmux-window-rules' (`notification_notices_attention_*`, see
/// `AttentionBannerLifecycle+Wire.swift`); the banner id stays here, as the notifier reads it.
public struct AttentionBannerLifecycle {
    public init() {}
    /// What changed in the marked tabs since the last list: the banners to post (a new mark, or a
    /// new request on a marked tab) and the banner ids to withdraw (a mark that cleared or was
    /// replaced). `previous == nil` is the first list of this launch: marks made before it post
    /// nothing, as notifications that arrived before launch do not.
    public nonisolated static func attentionChanges(previous: [AgentPaneAttentionTabs.Item]?, current: [AgentPaneAttentionTabs.Item])
        -> (post: [AgentPaneAttentionTabs.Item], withdraw: [String]) {
        AttentionBannerRules.changes(previous: previous, current: current, eligible: nil)
    }

    /// The watch has already classified current-launch changes per machine. Its eligible set
    /// may include a request seen earlier while the tree was unready, so don't diff it away.
    public nonisolated static func posts(previous: [AgentPaneAttentionTabs.Item]?, current: [AgentPaneAttentionTabs.Item],
                                         eligibleRequests: Set<String>?) -> [AgentPaneAttentionTabs.Item] {
        AttentionBannerRules.changes(previous: previous, current: current, eligible: eligibleRequests).post
    }

    /// One banner per request: a new request on the same tab is a new banner.
    public nonisolated static func attentionBannerID(_ item: AgentPaneAttentionTabs.Item) -> String {
        "\(attentionBannerPrefix)\(item.tabId)"
    }

    /// The tab a Needs you banner names, nil for any other banner.
    public nonisolated static func attentionTab(banner: String) -> String? {
        AttentionBannerRules.tab(banner: banner)
    }

    public nonisolated static let attentionBannerPrefix = "cmux-attention."

    /// Snapshot IDs from Notification Center minus requests this launch posted. Call this after
    /// the center answers, using the latest set, so a concurrent new banner is never withdrawn.
    public nonisolated static func staleBannerIDs(_ retained: [String], currentLaunch: Set<String>) -> [String] {
        AttentionBannerRules.stale(retained, currentLaunch: currentLaunch)
    }
}
