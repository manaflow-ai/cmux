import CmuxNextWindowRules

/// What cmux-window-rules `desktop_attention` answers (`window_notifications_desktop_attention_changes`,
/// `_tab`, `_stale`): indices into the marks sent, so the items stay here, and banner ids. No rule lives here.
extension AttentionBannerLifecycle {
    nonisolated struct MarksAsk: Encodable {
        var previous: [String]?
        var current: [String]
        var eligible: [String]?
    }

    nonisolated struct Changes: Decodable {
        var post: [Int]
        var withdraw: [String]
        var posts: [Int]
    }

    nonisolated struct BannerAsk: Encodable {
        var banner: String
    }

    nonisolated struct TabReply: Decodable {
        var tab: String?
    }

    nonisolated struct RetainedAsk: Encodable {
        var retained: [String]
        var currentLaunch: [String]
    }

    nonisolated struct StaleReply: Decodable {
        var stale: [String]
    }

    /// The marks' changes, by their tab ids; nil when the rule does not answer.
    nonisolated static func changes(previous: [AgentPaneAttentionTabs.Item]?, current: [AgentPaneAttentionTabs.Item],
                                    eligible: [String]?) -> Changes? {
        let ask = MarksAsk(previous: previous?.map(\.tabId), current: current.map(\.tabId), eligible: eligible)
        return WindowRules().call("window_notifications_desktop_attention_changes", ask, as: Changes.self)
    }

    /// The items at `indices` of `items`, in that order; an index out of range is skipped.
    nonisolated static func items(_ indices: [Int], of items: [AgentPaneAttentionTabs.Item]) -> [AgentPaneAttentionTabs.Item] {
        indices.compactMap { items.indices.contains($0) ? items[$0] : nil }
    }
}
