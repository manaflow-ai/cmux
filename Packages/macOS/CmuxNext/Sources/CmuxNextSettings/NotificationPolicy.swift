import CmuxNextWindowRules

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

/// The notification rules (plans/cmux-next/notifications.md), asked of Rust
/// (cmux-tui/crates/cmux-window-rules `notification_policy`, with their table
/// tests) over the app FFI: ops `window_notifications_decide` and
/// `window_notifications_clears_table`. The daemon owns unread state; these
/// rules only decide when the app acknowledges it and what an arrival shows.
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
        clearing[mode]?.contains(trigger) ?? false
    }

    /// Each mode's clearing triggers, asked once: a focus, click or keystroke reads the table.
    private static let clearing: [NotificationDismissal: Set<NotificationTrigger>] = {
        struct Empty: Encodable {}
        let table = WindowRules().call("window_notifications_clears_table", Empty(), as: [String: [String]].self) ?? [:]
        return Dictionary(uniqueKeysWithValues: table.compactMap { mode, triggers in
            NotificationDismissal(rawValue: mode).map { ($0, Set(triggers.compactMap(NotificationTrigger.init(rawValue:)))) }
        })
    }()

    /// What the app knows when a notification arrives.
    public struct Arrival: Hashable, Sendable {
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

    public struct Decision: Hashable, Sendable {
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

    public func decide(_ arrival: Arrival) -> Decision {
        struct Request: Encodable { var prefs: NotificationPreferences.Wire, arrival: Arrival.Wire }
        let request = Request(prefs: NotificationPreferences.Wire(prefs), arrival: Arrival.Wire(arrival))
        return WindowRules().call("window_notifications_decide", request, as: Decision.Wire.self)?.decision ?? Decision()
    }
}
