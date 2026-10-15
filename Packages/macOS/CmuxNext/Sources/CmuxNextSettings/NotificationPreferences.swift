public import CmuxNextDesign
public import Foundation

/// Everything under `notifications` in cmux.json that the app applies.
public nonisolated struct NotificationPreferences: Hashable, Sendable {
    public var dismissal: NotificationDismissal = .keystroke
    public var timeoutSeconds: Double = 30
    public var desktop: DesktopNotificationMode = .unlessFocused
    /// `"default"`, a sound in /System/Library/Sounds (for example `"Glass"`), or `"none"`.
    public var sound = "default"
    public var quietHours: QuietHours?
    /// A notification for a pane typed into within this many seconds is
    /// read at once (no ring, banner or sound). 0 turns it off.
    public var suppressWhileTypingSeconds: Double = 0
    public var dockBadge = true
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
