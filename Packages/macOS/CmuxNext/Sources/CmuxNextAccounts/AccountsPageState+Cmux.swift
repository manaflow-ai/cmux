import Foundation

extension AccountsPageState {
    /// cmux's own row: the account, where a sign-in stands, and its buttons
    /// (by id: `cmux.signIn`, `cmux.cancelSignIn`, `cmux.continueInBrowser`,
    /// `cmux.switchAccount`, `cmux.signOut`).
    public struct Cmux: Encodable, Equatable, Sendable {
        public let title: String
        public let detail: String?
        public let status: String
        /// `success`, `attention`, `neutral` or `quiet` (the status dot).
        public let statusKind: String
        public let busy: Bool
        public let buttons: [Button]
        /// A hint while the sign-in waits in the browser.
        public let note: String?
        public let error: String?
    }
}

extension AccountsModel {
    static func cmuxRow(_ account: CmuxAccountState) -> AccountsPageState.Cmux {
        typealias Button = AccountsPageState.Button
        func button(_ action: CmuxAccountAction, _ title: String, destructive: Bool = false) -> Button {
            Button(id: "cmux.\(action.rawValue)", title: title, disabled: false, help: nil, destructive: destructive)
        }
        let error = account.failed ? AccountsStrings.cmuxSignInFailed : nil
        if account.signingIn {
            return .init(title: AccountsStrings.cmuxTitle, detail: account.label, status: AccountsStrings.cmuxSigningIn,
                         statusKind: "neutral", busy: true,
                         buttons: [button(.continueInBrowser, AccountsStrings.cmuxOpenInBrowser),
                                   button(.cancelSignIn, AccountsStrings.cancel)],
                         note: account.waitingForBrowser ? AccountsStrings.cmuxFinishInBrowser : nil, error: nil)
        }
        if account.signedIn {
            return .init(title: AccountsStrings.cmuxTitle, detail: account.label, status: AccountsStrings.cmuxSignedIn,
                         statusKind: "success", busy: false,
                         buttons: [button(.switchAccount, AccountsStrings.cmuxSwitchAccount),
                                   button(.signOut, AccountsStrings.cmuxSignOut, destructive: true)],
                         note: nil, error: error)
        }
        return .init(title: AccountsStrings.cmuxTitle, detail: nil, status: AccountsStrings.cmuxSignedOut,
                     statusKind: account.failed ? "attention" : "quiet", busy: false,
                     buttons: [button(.signIn, AccountsStrings.signInToCmux)],
                     note: nil, error: error)
    }
}

extension AccountsStrings {
    static var cmuxTitle: String { text("accounts.cmux.title", "cmux Account") }
    static var cmuxSignedIn: String { text("accounts.status.signedIn", "Signed in") }
    static var cmuxSignedOut: String { text("accounts.cmux.signedOut", "Signed out") }
    static var cmuxSigningIn: String { text("accounts.cmux.signingIn", "Signing in…") }
    static var cmuxFinishInBrowser: String {
        text("accounts.cmux.finishInBrowser", "Finish signing in in your browser. If no page opened, choose Open in Browser.")
    }
    static var cmuxOpenInBrowser: String { text("accounts.cmux.openInBrowser", "Open in Browser") }
    static var cmuxSwitchAccount: String { text("accounts.cmux.switchAccount", "Switch Account…") }
    static var cmuxSignOut: String { text("accounts.cmux.signOut", "Sign Out") }
    static var cmuxSignInFailed: String { text("accounts.cmux.signInFailed", "Sign-in did not finish. Try again.") }
}
