import CmuxNextSettings

/// A user interaction with a pane that has an unread notification.
enum NotificationTrigger: String, Hashable, Sendable {
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
/// decide when the app acknowledges it and what an arrival shows.
enum NotificationPolicy {
    /// Whether `trigger` acknowledges a notification under `mode`. The
    /// dismiss verbs (Mark Read, Mark All Read, CLI clear) always do and do
    /// not come here.
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
    struct Arrival: Hashable, Sendable {
        var source: NotificationSource
        var workspaceMuted = false
        /// The pane is the focused pane of the key window and cmux is active.
        var paneIsViewed = false
        var appActive = false
        /// Local minutes after midnight, for quiet hours.
        var minuteOfDay = 12 * 60
        /// Seconds since the last keystroke in the notifying pane, if any.
        var typedAgo: Double?
    }

    struct Decision: Hashable, Sendable {
        /// Acknowledge at once: it is already seen.
        var acknowledge = false
        /// Draw the pane attention ring.
        var attention = true
        var desktop = false
        /// The sound to play, nil for none.
        var sound: String?
        /// Acknowledge after this many seconds unless cleared earlier.
        var timeout: Double?
    }

    static func decide(_ arrival: Arrival, prefs: NotificationPreferences) -> Decision {
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
            case .always: decision.desktop = true
            case .unlessFocused: decision.desktop = !arrival.paneIsViewed
            case .whenInactive: decision.desktop = !arrival.appActive
            case .never: decision.desktop = false
            }
        }
        let sound = prefs.sound(for: arrival.source)
        if !arrival.workspaceMuted && !quiet && !arrival.paneIsViewed && sound != "none" {
            decision.sound = sound
        }
        if mode == .timeout { decision.timeout = prefs.timeoutSeconds }
        return decision
    }
}
