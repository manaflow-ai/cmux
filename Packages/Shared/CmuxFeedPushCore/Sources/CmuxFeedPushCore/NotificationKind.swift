/// What a push is about, as the notification preferences group them. Feed
/// kinds follow the owner's kinds (feed.md 3.4); terminal alerts are bells
/// and `cmux.terminal`. The feed owner maps items with the same table
/// (backend `push/notify-kind.ts`), so a kind turned off on this device is
/// not sent to it.
public enum NotificationKind: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case permission
    case question
    case planApproval
    case finished
    case terminalAlert

    public var id: String { rawValue }

    /// The kind of one push: from the category when it names one, else from
    /// the feed kind and type. Nil when the push is none of these (it is
    /// shown as sent).
    public init?(feedKind: String?, type: String?, category: String?) {
        switch category {
        case FeedPushCategory.approve.rawValue, FeedPushCategory.approveScoped.rawValue: self = .permission; return
        case FeedPushCategory.plan.rawValue: self = .planApproval; return
        case FeedPushCategory.notice.rawValue: self = .finished; return
        case PushTerminalCategory.terminal: self = .terminalAlert; return
        default: break
        }
        if type == "notice" { self = .finished; return }
        switch feedKind {
        case "approve": self = .permission
        case "question", "choice", "confirm", "input", "file": self = .question
        case "review": self = .planApproval
        case "notice": self = .finished
        default: return nil
        }
    }

    /// Kinds that ask the user for something now; they may break through
    /// Focus when the device allows time-sensitive pushes.
    public var isRequest: Bool {
        switch self {
        case .permission, .question, .planApproval: true
        case .finished, .terminalAlert: false
        }
    }
}
