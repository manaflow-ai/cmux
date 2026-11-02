public import CmuxNextCompat
public import CmuxNextDesign
public import Foundation

/// Everything under `notifications` in cmux.json that the app applies.
public nonisolated struct NotificationPreferences: Hashable, Sendable {
    /// `focus`, as in cmux classic: attention is one on/off state per pane, cleared when the pane is
    /// selected, including by entering its workspace, and an event on the pane the person looks at
    /// sets none (https://github.com/manaflow-ai/cmux/issues/25662). Under `click` (2026-10-20) a
    /// selected pane kept its ring and every later event rang it again, so it came back several
    /// times before a click cleared it; `click` stays a choice in Settings.
    public var dismissal: NotificationDismissal = .focus
    public var timeoutSeconds: Double = 30
    public var desktop: DesktopNotificationMode = .unlessFocused
    /// `"default"`, a sound in /System/Library/Sounds (for example `"Glass"`), or `"none"`.
    public var sound = "default"
    /// `notifications.sounds`: per-event sounds, volume, timing, the burst cooldown, and the
    /// workspace, group and agent levels (``NotificationSoundPreferences``).
    public var sounds = NotificationSoundPreferences()
    public var quietHours: QuietHours?
    /// A notification for a pane typed into within this many seconds is
    /// read at once (no ring, banner or sound). 0 turns it off.
    public var suppressWhileTypingSeconds: Double = 0
    public var dockBadge = true
    /// `notifications.dockBounce`: the Dock icon bounces when an alert arrives while cmux is inactive.
    public var dockBounce: DockBounceMode = .once
    /// `notifications.showPreviews`: when a banner shows the agent's last message.
    public var showPreviews: NotificationPreviews = .whenUnlocked
    /// Workspace ids whose notifications post no banner, sound or ring.
    public var mutedWorkspaces: Set<String> = []
    public var sources: [NotificationSource: NotificationSourceOverrides] = [:]
    /// `feed.mirrorNotifications`: what the app copies into the cloud feed.
    public var feedMirror = FeedMirrorPreferences()

    public init() {}

    public static let timeoutRange: ClosedRange<Double> = 1...86_400
    public static let typingRange: ClosedRange<Double> = 0...60

    public func dismissal(for source: NotificationSource) -> NotificationDismissal {
        sources[source]?.dismissal ?? dismissal
    }

    public func sound(for source: NotificationSource) -> String {
        sources[source]?.sound ?? sound
    }

    public func postsDesktop(for source: NotificationSource) -> Bool {
        sources[source]?.desktop ?? true
    }
}
