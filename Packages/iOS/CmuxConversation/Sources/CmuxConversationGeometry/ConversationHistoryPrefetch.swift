import CoreGraphics

/// When the transcript asks for older history while the reader scrolls.
///
/// Messages reads history from the device's database, so its 50-message
/// page (`CKUIBehavior.defaultConversationLoadMoreCount`) is there at once.
/// Ours comes over the network: about a second per page (the conversation
/// simulator's history latency, median 1.1 s), during which a fling covers
/// several screens. Asked for at 1.5 screens from the top, a hard fling
/// reached the top of what was loaded and bounced there until the page
/// came. The request now goes out four screens ahead.
// lint:allow namespace-type -- vendored CmuxConversation snapshot
public enum ConversationHistoryPrefetch {
    public enum Decision: Equatable, Sendable {
        /// Ask for the page above (coalesced while one is on its way).
        case load
        /// The reader went back down: a failed request stops retrying.
        case stop
        case none
    }

    /// Screens from the top within which the page above is asked for.
    public static let loadWithin: CGFloat = 4
    /// Screens from the top beyond which it is no longer wanted.
    public static let stopBeyond: CGFloat = 6

    /// `distanceFromTop`: the current offset, or a fling's resting offset,
    /// from the top of the loaded transcript.
    public static func decision(distanceFromTop: CGFloat, viewport: CGFloat) -> Decision {
        if distanceFromTop < viewport * loadWithin { return .load }
        if distanceFromTop > viewport * stopBeyond { return .stop }
        return .none
    }
}
