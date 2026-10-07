/// The notification category the feed owner sets in `aps.category`
/// (`FEED_<KIND>` for requests, `FEED_NOTICE` for notices, with
/// `FEED_APPROVE_SESSION` and `FEED_PLAN` refining approve and review).
public enum FeedPushCategory: String, CaseIterable, Hashable, Sendable {
    case approve = "FEED_APPROVE"
    /// An approve request that offers the session scope.
    case approveScoped = "FEED_APPROVE_SESSION"
    case confirm = "FEED_CONFIRM"
    case choice = "FEED_CHOICE"
    case question = "FEED_QUESTION"
    /// A review of a plan.
    case plan = "FEED_PLAN"
    /// Any other review (diff, PR, file, document, url): opened in the app.
    case review = "FEED_REVIEW"
    case signIn = "FEED_SIGN_IN"
    case passkey = "FEED_PASSKEY"
    case handoff = "FEED_HANDOFF"
    case notice = "FEED_NOTICE"

    /// The buttons the banner offers, in order. An empty list means the
    /// default action only (a tap opens the item).
    public var actions: [FeedPushAction] {
        switch self {
        case .approve: [.allow, .deny]
        // The owner refuses a scope the prompt did not offer, so the session
        // scope appears only on the category the owner picked for it.
        case .approveScoped: [.allowOnce, .allowForSession, .deny]
        case .confirm: [.confirm, .cancel]
        case .question: [.reply]
        case .plan: [.approvePlan, .requestChanges]
        // Sign-in, passkey and handoff need the Mac; the owner refuses phone answers.
        case .signIn, .passkey, .handoff: [.openOnMac]
        case .notice: [.markRead]
        case .choice, .review: []
        }
    }

    /// The category for an item, derived the way the owner derives it (used
    /// by the Notification Service extension when a push names none).
    public init?(feedKind: String?, type: String?, scopes: [String], subject: String?) {
        if type == "notice" { self = .notice; return }
        switch feedKind {
        case "approve": self = scopes.contains("session") ? .approveScoped : .approve
        case "review": self = subject == "plan" ? .plan : .review
        case "sign-in": self = .signIn
        case let kind?:
            guard let category = FeedPushCategory(rawValue: "FEED_" + kind.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()) else { return nil }
            self = category
        case nil: return nil
        }
    }
}
