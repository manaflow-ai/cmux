/// A user interaction with a pane that has an unread notification.
public nonisolated enum NotificationTrigger: String, Hashable, Sendable {
    /// The pane became the focused pane of the key window while cmux is active.
    case focus
    /// A mouse-down in the pane.
    case click
    /// A key typed into the pane's terminal or page (not an app shortcut).
    case keystroke
    /// The notification was opened: jump to unread, a banner click, Open Notification.
    case open
    /// The `timeout` dismissal deadline passed.
    case timeout
}

/// The notification rules (plans/cmux-next/notifications.md), pure so every
/// case is a table test. The daemon owns unread state; these rules only
/// decide when the app acknowledges it and what an arrival shows. Lives
/// beside the preferences it reads, outside the App target (SW14).
public nonisolated struct NotificationPolicy: Sendable {
    public let prefs: NotificationPreferences

    public init(prefs: NotificationPreferences) {
        self.prefs = prefs
    }

    /// Whether `trigger` acknowledges a notification under `mode`. The
    /// dismiss verbs (Mark Read, Mark All Read, CLI clear) always do and do
    /// not come here.
    public func clears(_ trigger: NotificationTrigger, for source: NotificationSource) -> Bool {
        Self.clears(trigger, mode: prefs.dismissal(for: source))
    }

    static func clears(_ trigger: NotificationTrigger, mode: NotificationDismissal) -> Bool {
        let request: JSONValue = ["prefs": ["dismissal": .string(mode.rawValue)], "trigger": .string(trigger.rawValue)]
        return SettingsRust.answer("notifications.clears", request)["clears"]?.boolValue ?? false
    }

    /// What the app knows when a notification arrives.
    public struct Arrival: Hashable, Sendable, Encodable {
        public var source: NotificationSource
        public var workspaceMuted = false
        /// The pane is the focused pane of the key window and cmux is active.
        public var paneIsViewed = false
        public var appActive = false
        /// Local minutes after midnight, for quiet hours.
        public var minuteOfDay = 12 * 60
        /// Seconds since the last keystroke in the notifying pane, if any.
        public var typedAgo: Double?
        /// The poster allows a banner (false for `notify --desktop false`).
        public var bannerAllowed = true
        /// What the notification is about, for its sound; nil reads it from the source alone
        /// (an agent's is a finished turn, a terminal's a bell, the CLI's a message).
        public var soundEvent: NotificationSoundEvent?
        /// The agent kind, workspace and groups whose sound levels apply.
        public var soundScope = NotificationSoundScope()

        public init(source: NotificationSource) {
            self.source = source
        }
    }

    public struct Decision: Hashable, Sendable, Decodable {
        /// Acknowledge at once: it is already seen.
        public var acknowledge = false
        /// Draw the pane attention ring.
        public var attention = true
        /// It would alert (banner) were the poster not asking for none:
        /// the phone push follows this, as classic's did.
        public var alerts = false
        public var desktop = false
        /// The sound to play, nil for none.
        public var sound: String?
        /// 0 to 1: how loud `sound` plays when cmux plays it itself (not a banner's default sound).
        public var soundVolume: Double = 1
        /// What the notification is about (its sound's event), for the burst cooldown.
        public var soundEvent: NotificationSoundEvent = .message
        /// The level that chose `sound` (``NotificationSoundChoice/level``), for the debug log.
        public var soundLevel: String?
        /// Acknowledge after this many seconds unless cleared earlier.
        public var timeout: Double?
        /// Bounce the Dock icon: it alerts while cmux is inactive (`notifications.dockBounce`).
        public var bounce: DockBounceMode?

        public init() {}
    }

    /// What an arrival shows and sounds (Rust `notifications.decide`).
    public func decide(_ arrival: Arrival) -> Decision {
        let reply = SettingsRust.answer("notifications.decide", ["prefs": SettingsRust.json(prefs), "arrival": SettingsRust.json(arrival)])
        return SettingsRust.decode(reply["decision"]) ?? Decision()
    }
}
