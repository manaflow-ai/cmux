public import CmuxNextCompat

extension DaemonNotification {
    /// The poster's subtitle (`cmux notify --subtitle`), unless empty.
    public var shownSubtitle: String? { subtitle.flatMap { $0.isEmpty ? nil : $0 } }

    /// The banner's text: the poster's own body, else an agent's last message (`preview`, a
    /// finished turn) as `previews` allows: always, only while the screen is unlocked, or never.
    public func bannerBody(previews: NotificationPreviews, screenLocked: Bool) -> String {
        guard body.isEmpty, let preview, !preview.isEmpty else { return body }
        switch previews {
        case .always: return preview
        case .whenUnlocked: return screenLocked ? "" : preview
        case .never: return ""
        }
    }
}
