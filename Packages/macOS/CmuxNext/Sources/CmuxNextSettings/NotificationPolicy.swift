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
        switch mode {
        case .focus: trigger != .timeout
        case .click: [.click, .keystroke, .open].contains(trigger)
        case .keystroke: [.keystroke, .open].contains(trigger)
        case .explicit: trigger == .open
        case .timeout: [.open, .timeout].contains(trigger)
        case .never: false
        }
    }

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
        var decision = Decision()
        let mode = prefs.dismissal(for: arrival.source)
        if prefs.suppressWhileTypingSeconds > 0, let typed = arrival.typedAgo, typed <= prefs.suppressWhileTypingSeconds {
            decision.acknowledge = true
            decision.attention = false
            return decision
        }
        if mode == .focus && arrival.paneIsViewed {
            decision.acknowledge = true
            decision.attention = false
            return decision
        }
        let quiet = prefs.quietHours?.contains(minuteOfDay: arrival.minuteOfDay) ?? false
        if arrival.workspaceMuted { decision.attention = false }
        if !arrival.workspaceMuted && !quiet && prefs.postsDesktop(for: arrival.source) {
            switch prefs.desktop {
            case .always: decision.alerts = true
            case .unlessFocused: decision.alerts = !arrival.paneIsViewed
            case .whenInactive: decision.alerts = !arrival.appActive
            case .never: decision.alerts = false
            }
        }
        decision.desktop = decision.alerts && arrival.bannerAllowed
        let event = arrival.soundEvent ?? NotificationSoundEvent(source: arrival.source, level: .info)
        decision.soundEvent = event
        if !arrival.workspaceMuted, !quiet, prefs.sounds.when.plays(viewed: arrival.paneIsViewed, appActive: arrival.appActive),
           let choice = prefs.sounds.choice(for: event, in: arrival.soundScope, fallback: prefs.sound(for: arrival.source)) {
            decision.sound = choice.name
            decision.soundVolume = choice.volume
            decision.soundLevel = choice.level
        }
        if mode == .timeout { decision.timeout = prefs.timeoutSeconds }
        // A poster asking for no banner (`notify --desktop false`) gets no bounce either.
        if decision.desktop, !arrival.appActive, prefs.dockBounce != .off { decision.bounce = prefs.dockBounce }
        return decision
    }
}
