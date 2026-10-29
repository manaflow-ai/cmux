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

    /// The source a daemon sends (`notification-source-v1`). `daemon` producers and daemons
    /// without sources count as agent, as before sources existed.
    public init(wire: String?) {
        self = wire.flatMap(NotificationSource.init(rawValue:)) ?? .agent
    }
}

public nonisolated extension NotificationSource {
    /// What Settings calls this source (`notifications.sources.<source>`), for
    /// any UI that names a notification's producer. One name and one catalog
    /// key, so a row reads the way the setting that governs it does.
    var settingsTitle: SettingText {
        switch self {
        case .cli: SettingsText.keyed("settings.notifications.source.cli", "cmux notify")
        case .terminal: SettingsText.keyed("settings.notifications.source.terminal", "Terminal Programs")
        case .agent: SettingsText.keyed("settings.notifications.source.agent", "Agents")
        }
    }
}

/// Per-source overrides (`notifications.sources.<source>`); nil keeps the global value.
public nonisolated struct NotificationSourceOverrides: Hashable, Sendable {
    public var dismissal: NotificationDismissal?
    public var color: ThemeRGB?
    public var sound: String?
    public var desktop: Bool?

    public init() {}
}
