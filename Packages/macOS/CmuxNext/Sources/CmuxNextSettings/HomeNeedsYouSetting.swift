/// `feed.needsYouInChief` in cmux.json: whether Chief Home pins the Feed's open requests (permission
/// prompts, questions, sign-ins) in a Needs you card under its header (`FeedNeedsYouPin`). Off by
/// default: the Feed itself always lists them. Leo 2026-11-03: "I just wanted to see permission
/// things, period, not a pinned thing by default. Toggle-on, yes, but I haven't verified the looks
/// of that yet". Its look (Debug Settings > Feed > Needs you in Home, `feed.needsYouStyle`) applies
/// only while this is on.
public nonisolated struct HomeNeedsYouSetting {
    public nonisolated init() {}
    public static let configPath = ["feed", "needsYouInChief"]
    public static let key = configPath.joined(separator: ".")
    /// Off until the person turns it on.
    public static let fallback = false

    /// Whether the pinned card is on in `settings` now (the default without them), read each call so
    /// an observation that calls it follows a change live.
    @MainActor public static func reader(_ settings: @escaping () -> SettingsController?) -> () -> Bool {
        { settings()?.snapshot.homeNeedsYouInChief ?? fallback }
    }
}

nonisolated extension CmuxConfigSnapshot {
    /// `feed.needsYouInChief`; a value that is not a bool reads as the default (the schema row's
    /// validation reports it).
    public var homeNeedsYouInChief: Bool {
        root.value(at: HomeNeedsYouSetting.configPath)?.boolValue ?? HomeNeedsYouSetting.fallback
    }
}
