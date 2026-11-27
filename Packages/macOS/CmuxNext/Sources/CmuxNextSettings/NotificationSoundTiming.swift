/// When a notification plays its sound (`notifications.sounds.when`).
public nonisolated enum NotificationSoundTiming: String, Hashable, Sendable, CaseIterable {
    /// Unless the notifying pane is the one in front of the person (the default, as before).
    case unlessViewed
    /// Only while cmux is not the active app.
    case whenInactive
    /// Every time, even for the pane in front of the person.
    case always

    /// Whether a sound plays for a pane that is `viewed`, while cmux is `appActive` or not.
    public func plays(viewed: Bool, appActive: Bool) -> Bool {
        switch self {
        case .unlessViewed: !viewed
        case .whenInactive: !appActive
        case .always: true
        }
    }
}
