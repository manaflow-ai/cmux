import CoreGraphics

/// When a banner shows what the agent said (its last message, `DaemonNotification.preview`),
/// named like macOS's own Show Previews. The app keeps it at `whenUnlocked` until the
/// `notifications.showPreviews` setting lands.
public enum NotificationPreviews: String, Hashable, Sendable, CaseIterable {
    case always
    /// Not while the screen is locked (default).
    case whenUnlocked
    case never

    /// Whether the login session's screen is locked now, as the window server reports it.
    public static var screenIsLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

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
