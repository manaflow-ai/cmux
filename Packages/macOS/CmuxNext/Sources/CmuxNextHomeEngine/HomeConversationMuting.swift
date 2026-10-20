public import CmuxHomeCore

/// Hide Alerts for one conversation: the seam ``HomeGroupActions`` mutes through. The app's
/// ``HomeSidebarSource`` is the one conformer (`inbox.mute` with the owner that lists the row);
/// tests pass a fake that records the calls.
@MainActor
public protocol HomeConversationMuting: AnyObject, Sendable {
    /// Whether `id` can be muted (a Cloud DM or group its owner lists).
    func canMute(_ id: ConversationID) -> Bool
    /// Whether `id`'s alerts are hidden.
    func isMuted(_ id: ConversationID) -> Bool
    /// Hides (`on`) or shows the alerts of `id`.
    func setMuted(_ on: Bool, _ id: ConversationID)
}
