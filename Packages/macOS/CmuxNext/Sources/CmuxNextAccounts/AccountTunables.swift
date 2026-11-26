public import CmuxNextDesign

/// The Debug Settings choice behind CmuxNextCloud's `CloudSignInWindow`
/// (same raw values; CmuxNextCloud does not see tunables).
public nonisolated enum SignInWindowChoice: String, Sendable, CaseIterable, TunableChoice {
    case automatic, popup, defaultBrowser

    public var tunableTitle: String {
        switch self {
        case .automatic: "Automatic (popup with Safari, else the default browser)"
        case .popup: "Popup"
        case .defaultBrowser: "Default browser"
        }
    }
}

/// Debug Settings of the cmux account (DEV and NIGHTLY; Release uses the defaults).
public nonisolated struct AccountTunables {
    public nonisolated init() {}
    static let section = TunableSection(id: "accounts", title: "Accounts", symbol: "person.crop.circle", order: 47)

    /// Where Sign In to cmux opens. Every entry point goes through CloudAuth.beginSignIn.
    public static let signInWindow = Tunable<SignInWindowChoice>.choice(
        "auth.signInWindow", section, "cmux sign-in window",
        help: "Where Sign In to cmux opens. Automatic uses the popup only when Safari is the default browser.",
        default: .automatic, code: "AccountTunables.signInWindow")

    public static var all: [TunableDescriptor] { [signInWindow.descriptor] }
}
