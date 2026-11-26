public import CmuxNextDesign

/// The Debug Settings choice behind CmuxNextCloud's `CloudSignInWindow`
/// (same raw values; CmuxNextCloud does not see tunables).
public nonisolated enum SignInWindowChoice: String, Sendable, CaseIterable, TunableChoice {
    case automatic, inApp, popup, defaultBrowser

    public var tunableTitle: String {
        switch self {
        case .automatic: "Automatic (in-app browser tab)"
        case .inApp: "In-app browser tab"
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
        help: "Where Sign In to cmux opens. Automatic uses a cmux browser tab (passkeys and the emailed code work there); with no window it uses the popup when Safari is the default browser, else the default browser.",
        default: .automatic, code: "AccountTunables.signInWindow")

    public static var all: [TunableDescriptor] { [signInWindow.descriptor] }
}
