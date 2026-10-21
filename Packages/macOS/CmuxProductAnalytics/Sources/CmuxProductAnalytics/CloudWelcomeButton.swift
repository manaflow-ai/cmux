/// A button on the welcome card.
public enum CloudWelcomeButton: String, Sendable, CaseIterable {
    case upgrade
    case enable
    case signIn = "sign_in"
    case openCloud = "open_cloud"
    /// Not Now, the card's own close button, or Escape.
    case notNow = "not_now"

    /// The button that performs `step`.
    public init(step: CloudWelcomeStep) {
        switch step {
        case .upgrade: self = .upgrade
        case .enable: self = .enable
        case .signIn: self = .signIn
        case .openCloud: self = .openCloud
        }
    }
}
