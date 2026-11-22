/// `feed.mirrorNotifications.terminal`: what of a terminal program's
/// notification (OSC 9/777/99) the app copies into the cloud feed. Program
/// output can hold secrets, so the default copies nothing.
public nonisolated enum FeedTerminalMirror: String, Hashable, Sendable, CaseIterable {
    /// Not mirrored (default).
    case off
    /// The title only (no body, no tab title).
    case title
    /// Title and body.
    case full
}

/// `feed.mirrorNotifications` (plans/cmux-next/feed.md section 9): which
/// daemon notifications the app also posts to the user's feed.
public nonisolated struct FeedMirrorPreferences: Hashable, Sendable {
    /// Notices from agents, agent hooks and `cmux notify`.
    public var agents = true
    public var terminal: FeedTerminalMirror = .off
    public init() {}
}
