public import CmuxNextDesign

/// Where a notification came from; `notifications.sources.<source>` can
/// override the defaults per source.
public nonisolated enum NotificationSource: String, Hashable, Sendable, CaseIterable {
    /// `cmux notify` and the `notification.create*` socket methods.
    case cli
    /// A terminal program: OSC 9, OSC 777 or OSC 99.
    case terminal
    /// An agent hook (Claude Code, Codex) or any daemon-side producer.
    case agent
}

/// Per-source overrides (`notifications.sources.<source>`); nil keeps the global value.
public nonisolated struct NotificationSourceOverrides: Hashable, Sendable {
    public var dismissal: NotificationDismissal?
    public var color: ThemeRGB?
    public var sound: String?
    public var desktop: Bool?

    public init() {}
}
