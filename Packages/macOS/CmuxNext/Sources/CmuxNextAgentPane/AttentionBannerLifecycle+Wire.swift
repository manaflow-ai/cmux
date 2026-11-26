import CmuxNextWindowRules

/// ``AttentionBannerLifecycle``'s rules, asked of cmux-window-rules `notification_notices` over
/// the app FFI's JSON channel. Marks go by tab id; the posts come back as indices into the
/// current list. With no answer (logged by ``WindowRules``) nothing posts, nothing is withdrawn,
/// and no banner names a tab.
nonisolated enum AttentionBannerRules {
    /// The marks of `current` to post and the banner ids to withdraw since `previous`; with
    /// `eligible`, the watch's classified requests post instead of the new marks.
    static func changes(previous: [AgentPaneAttentionTabs.Item]?, current: [AgentPaneAttentionTabs.Item], eligible: Set<String>?)
        -> (post: [AgentPaneAttentionTabs.Item], withdraw: [String]) {
        let request = ChangesRequest(previous: previous?.map(\.tabId), current: current.map(\.tabId), eligible: eligible?.sorted())
        guard let reply = WindowRules().call("notification_notices_attention_changes", request, as: ChangesReply.self) else {
            return ([], [])
        }
        let post = reply.post.compactMap { current.indices.contains($0) ? current[$0] : nil }
        return (post, reply.withdraw)
    }

    /// The tab Needs you banner `banner` names.
    static func tab(banner: String) -> String? {
        let reply = WindowRules().call("notification_notices_banner", BannerRequest(banner: banner), as: BannerReply.self)
        guard let found = reply?.banner, found.notice == "attention" else { return nil }
        return found.id
    }

    /// The Needs you banners of `retained` this launch did not post.
    static func stale(_ retained: [String], currentLaunch: Set<String>) -> [String] {
        let request = StaleRequest(retained: retained, currentLaunch: currentLaunch.sorted())
        return WindowRules().call("notification_notices_attention_stale", request, as: StaleReply.self)?.stale ?? []
    }
}

private nonisolated struct ChangesRequest: Encodable {
    var previous: [String]?
    var current: [String]
    var eligible: [String]?
}

private nonisolated struct ChangesReply: Decodable {
    var post: [Int]
    var withdraw: [String]
}

private nonisolated struct BannerRequest: Encodable {
    var banner: String
}

private nonisolated struct BannerReply: Decodable {
    struct Banner: Decodable {
        var notice: String
        var id: String
    }

    var banner: Banner?
}

private nonisolated struct StaleRequest: Encodable {
    var retained: [String]
    var currentLaunch: [String]
}

private nonisolated struct StaleReply: Decodable {
    var stale: [String]
}
