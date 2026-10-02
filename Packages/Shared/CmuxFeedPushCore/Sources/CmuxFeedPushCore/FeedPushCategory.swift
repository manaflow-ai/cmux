/// The notification category the feed owner sets in `aps.category`
/// (`FEED_<KIND>` for requests, `FEED_NOTICE` for notices).
public enum FeedPushCategory: String, CaseIterable, Hashable, Sendable {
    case approve = "FEED_APPROVE"
    case confirm = "FEED_CONFIRM"
    case choice = "FEED_CHOICE"
    case question = "FEED_QUESTION"
    case signIn = "FEED_SIGN_IN"
    case passkey = "FEED_PASSKEY"
    case handoff = "FEED_HANDOFF"
    case notice = "FEED_NOTICE"

    /// The buttons the banner offers, in order. An empty list means the
    /// default action only (a tap opens the item).
    public var actions: [FeedPushAction] {
        switch self {
        case .approve: [.allow, .allowForSession, .deny]
        case .confirm: [.confirm, .cancel]
        case .question: [.reply]
        // Sign-in, passkey and handoff need the Mac; the owner refuses phone answers.
        case .signIn, .passkey, .handoff: [.openOnMac]
        case .choice, .notice: []
        }
    }
}

/// One banner action. Identifiers are stable: they travel in
/// `UNNotificationResponse.actionIdentifier`.
public enum FeedPushAction: String, CaseIterable, Hashable, Sendable {
    case allow = "FEED_ALLOW"
    case allowForSession = "FEED_ALLOW_SESSION"
    case deny = "FEED_DENY"
    case confirm = "FEED_CONFIRM_YES"
    case cancel = "FEED_CONFIRM_NO"
    case reply = "FEED_REPLY"
    case openOnMac = "FEED_OPEN_ON_MAC"

    /// How the action behaves on the banner.
    public enum Style: Hashable, Sendable {
        /// Answers from the banner, without opening the app.
        case answer(destructive: Bool, requiresUnlock: Bool)
        /// A text field; the typed text is the answer.
        case textInput
        /// Opens the app (nothing is answered from the phone).
        case openApp
    }

    public var style: Style {
        switch self {
        // Approving work an agent asked for needs an unlocked phone.
        case .allow, .allowForSession: .answer(destructive: false, requiresUnlock: true)
        case .deny: .answer(destructive: true, requiresUnlock: false)
        case .confirm: .answer(destructive: false, requiresUnlock: true)
        case .cancel: .answer(destructive: true, requiresUnlock: false)
        case .reply: .textInput
        case .openOnMac: .openApp
        }
    }
}
