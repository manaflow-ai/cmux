/// What cmux-window-rules `desktop_bursts` answers (`window_notifications_desktop_burst_join`, `_read`):
/// the burst the app keeps per workspace, sent back with each step, and what joining or reading did.
/// No rule lives here.
extension FinishedBannerBursts {
    /// One workspace's open burst.
    struct Burst: Codable {
        /// Unread tabs whose agents finished in it, each once.
        var tabs: [String]
        /// Its banners still showing, oldest first.
        var showing: [Showing]
    }

    /// A banner the burst still shows, and the tab it is filed under.
    struct Showing: Codable {
        var id: String
        var tab: String
    }

    struct JoinAsk: Encodable {
        var burst: Burst?
        var notification: UInt64
        var finishedTurn: Bool
        var reply: Bool
        var tab: String
    }

    struct Joined: Decodable {
        /// Nil: the notification does not join (no burst opens, the open one stays).
        var burst: Burst?
        var digest: Digest?
    }

    struct ReadAsk: Encodable {
        var burst: Burst
        var tab: String
    }

    struct Left: Decodable {
        var burst: Burst
        /// The burst is left empty: it closes.
        var closes: Bool
    }
}
