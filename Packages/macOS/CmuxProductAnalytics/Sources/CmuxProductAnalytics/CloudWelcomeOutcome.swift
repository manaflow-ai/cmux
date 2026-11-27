/// How a shown welcome card ended.
public enum CloudWelcomeOutcome: String, Sendable, CaseIterable {
    case upgrade
    case enable
    case signIn = "sign_in"
    case openCloud = "open_cloud"
    case notNow = "not_now"
    /// The window closed with no button (Cmd-W, or the app quit).
    case windowClosed = "window_closed"

    /// The outcome recorded when `button` closed the card.
    public init(button: CloudWelcomeButton) {
        switch button {
        case .upgrade: self = .upgrade
        case .enable: self = .enable
        case .signIn: self = .signIn
        case .openCloud: self = .openCloud
        case .notNow: self = .notNow
        }
    }
}
