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
    public var agents = Self.agentsDefault
    public var terminal: FeedTerminalMirror = Self.terminalDefault
    /// `feed.agentPermissionPrompts`: each pending agent permission request
    /// (its tool and command summary) goes to the person's own feed, so the
    /// iPhone can answer it (cx-aocz). Off by default: it sends prompt text
    /// to the Cloud feed and pushes once per prompt.
    public var agentPermissionPrompts = Self.agentPermissionPromptsDefault
    public init() {}
}
