/// One banner action. Identifiers are stable: they travel in
/// `UNNotificationResponse.actionIdentifier`.
public enum FeedPushAction: String, CaseIterable, Hashable, Sendable {
    case allow = "FEED_ALLOW"
    case allowOnce = "FEED_ALLOW_ONCE"
    case allowForSession = "FEED_ALLOW_SESSION"
    case deny = "FEED_DENY"
    case confirm = "FEED_CONFIRM_YES"
    case cancel = "FEED_CONFIRM_NO"
    case reply = "FEED_REPLY"
    case approvePlan = "FEED_PLAN_APPROVE"
    case requestChanges = "FEED_PLAN_CHANGES"
    case markRead = "FEED_MARK_READ"
    case openOnMac = "FEED_OPEN_ON_MAC"

    /// How the action behaves on the banner.
    public enum Style: Hashable, Sendable {
        /// Answers (or triages) from the banner, without opening the app.
        case answer(destructive: Bool, requiresUnlock: Bool)
        /// A text field; the typed text is the answer.
        case textInput
        /// Opens the app (nothing is answered from the phone).
        case openApp
    }

    public var style: Style {
        switch self {
        // Approving work an agent asked for needs an unlocked phone.
        case .allow, .allowOnce, .allowForSession, .confirm, .approvePlan:
            .answer(destructive: false, requiresUnlock: true)
        case .deny, .cancel: .answer(destructive: true, requiresUnlock: false)
        case .markRead: .answer(destructive: false, requiresUnlock: false)
        case .reply, .requestChanges: .textInput
        case .openOnMac: .openApp
        }
    }
}
