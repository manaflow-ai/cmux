import CmuxNextCloud
import CmuxNextDesign

/// The Debug Settings choice behind ``CloudSignInWindow`` (CmuxNextCloud does not see tunables).
nonisolated enum SignInWindowChoice: String, Sendable, CaseIterable, TunableChoice {
    case automatic, popup, defaultBrowser

    var tunableTitle: String {
        switch self {
        case .automatic: "Automatic (popup with Safari, else the default browser)"
        case .popup: "Popup"
        case .defaultBrowser: "Default browser"
        }
    }

    var window: CloudSignInWindow {
        switch self {
        case .automatic: .automatic
        case .popup: .popup
        case .defaultBrowser: .defaultBrowser
        }
    }
}

/// Debug Settings of the cmux account (DEV and NIGHTLY; Release uses the defaults).
nonisolated enum AccountTunables {
    static let section = TunableSection(id: "accounts", title: "Accounts", symbol: "person.crop.circle", order: 47)

    /// Where Sign In to cmux opens. Every entry point goes through CloudAuth.beginSignIn.
    static let signInWindow = Tunable<SignInWindowChoice>.choice(
        "auth.signInWindow", section, "cmux sign-in window",
        help: "Where Sign In to cmux opens. Automatic uses the popup only when Safari is the default browser.",
        default: .automatic, code: "AccountTunables.signInWindow")

    static var all: [TunableDescriptor] { [signInWindow.descriptor] }
}
