public import AppKit
public import CmuxNextActions
public import CmuxNextWakeups

/// What the notification sound actions read from the App: the live preferences, the validated
/// cmux.json write, the targeted workspace and group, and the person's sidebar groups.
@MainActor
public protocol NotificationSoundHost: AnyObject {
    /// The notification preferences that apply now.
    var soundPreferences: NotificationPreferences { get }
    /// Applies `sounds` at once; the settings watcher reapplies cmux.json after the write.
    func applySoundPreferences(_ sounds: NotificationSoundPreferences)
    /// Writes `value` at `path` (nil removes it) through the validated settings path, as `writer`.
    /// Returns nil on success, else the failure.
    func writeSoundSetting(_ path: [String], _ value: JSONValue?, by writer: SettingWriter) async -> ActionWorkFailure?
    /// The invocation's workspace id; throws when it targets none.
    func soundWorkspace(_ invocation: ActionInvocation) throws -> String
    /// The invocation's workspace group (id and name); throws when it targets none.
    func soundGroup(_ invocation: ActionInvocation) throws -> NotificationSoundScope.Group
    /// The person's sidebar groups workspace `id` sits in, innermost first.
    func soundGroups(ofWorkspace id: String) -> [NotificationSoundScope.Group]
    /// The agent names of this Mac's tabs (the agent kinds the palette offers), any case.
    var soundAgentKinds: [String] { get }
    /// The window an open panel attaches to, if any.
    var soundAnchorWindow: NSWindow? { get }
    /// The app's lanes for blocking work (the library's disk reads and copies).
    var soundWork: BackgroundWork { get }
    /// What the person reads for an error the host threw.
    func soundRefusal(_ error: any Error) -> String
}
