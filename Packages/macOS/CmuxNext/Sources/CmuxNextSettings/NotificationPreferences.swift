public import CmuxNextDesign
public import Foundation

/// Everything under `notifications` in cmux.json that the app applies.
public nonisolated struct NotificationPreferences: Hashable, Sendable {
    /// `focus` (Lawrence, 2026-10-19): classic's rule, a focus, click or key in the pane reads it.
    public var dismissal: NotificationDismissal = .focus
    public var timeoutSeconds: Double = 30
    public var desktop: DesktopNotificationMode = .unlessFocused
    /// `"default"`, a sound in /System/Library/Sounds (for example `"Glass"`), or `"none"`.
    public var sound = "default"
    public var quietHours: QuietHours?
    /// A notification for a pane typed into within this many seconds is
    /// read at once (no ring, banner or sound). 0 turns it off.
    public var suppressWhileTypingSeconds: Double = 0
    public var dockBadge = true
    /// `notifications.dockBounce`: the Dock icon bounces when an alert arrives while cmux is inactive.
    public var dockBounce: DockBounceMode = .once
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
