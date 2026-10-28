/// Identity and set reconciliation for needs-you requests, independent of the system notifier.
public struct AttentionBannerLifecycle {
    private init() {}
    /// What changed in the marked tabs since the last list: the banners to post (a new mark, or a
    /// new request on a marked tab) and the banner ids to withdraw (a mark that cleared or was
    /// replaced). `previous == nil` is the first list of this launch: marks made before it post
    /// nothing, as notifications that arrived before launch do not.
    public nonisolated static func attentionChanges(previous: [AgentPaneAttentionTabs.Item]?, current: [AgentPaneAttentionTabs.Item])
        -> (post: [AgentPaneAttentionTabs.Item], withdraw: [String]) {
        guard let previous else { return ([], []) }
        let before = Set(previous.map(attentionBannerID))
        let now = Set(current.map(attentionBannerID))
        return (current.filter { !before.contains(attentionBannerID($0)) }, previous.map(attentionBannerID).filter { !now.contains($0) })
    }

    /// One banner per request: a new request on the same tab is a new banner.
    public nonisolated static func attentionBannerID(_ item: AgentPaneAttentionTabs.Item) -> String {
        "\(attentionBannerPrefix)\(item.atMs).\(item.tabId)"
    }

    /// The tab a Needs you banner names, nil for any other banner.
    public nonisolated static func attentionTab(banner: String) -> String? {
        guard banner.hasPrefix(attentionBannerPrefix) else { return nil }
        let rest = banner.dropFirst(attentionBannerPrefix.count)
        guard let dot = rest.firstIndex(of: "."), UInt64(rest[..<dot]) != nil else { return nil }
        let tab = rest[rest.index(after: dot)...]
        return tab.isEmpty ? nil : String(tab)
    }

    public nonisolated static let attentionBannerPrefix = "cmux-attention."

    /// Snapshot IDs from Notification Center minus requests this launch posted. Call this after
    /// the center answers, using the latest set, so a concurrent new banner is never withdrawn.
    public nonisolated static func staleBannerIDs(_ retained: [String], currentLaunch: Set<String>) -> [String] {
        retained.filter { $0.hasPrefix(attentionBannerPrefix) && !currentLaunch.contains($0) }
    }
}
