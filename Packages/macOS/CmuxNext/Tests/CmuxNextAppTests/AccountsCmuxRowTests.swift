import CmuxNextAccounts
import CmuxNextCloud
import Testing

/// Settings > Accounts, cmux's own row: who is signed in, a sign-in in
/// progress, a failed one, and the gestures each state offers.
@MainActor
@Suite struct AccountsCmuxRowTests {
    private func ids(_ row: AccountsPageState.Cmux) -> [String] { row.buttons.map(\.id) }

    @Test func aSignedInAccountOffersSwitchAndSignOut() {
        let services = MockAccountsServices()
        let row = AccountsModel(services: services).pageState.cmux
        #expect(row.status == "Signed in")
        #expect(row.detail == "d…@e…")
        #expect(ids(row) == ["cmux.switchAccount", "cmux.signOut"])
        #expect(row.buttons.last?.destructive == true)
    }

    @Test func aSignInInProgressOffersTheBrowserAndCancel() {
        let services = MockAccountsServices()
        services.isSignedInToCmux = false
        services.cmuxSignInState = CmuxAccountState(signedIn: false, signingIn: true, waitingForBrowser: true)
        let row = AccountsModel(services: services).pageState.cmux
        #expect(row.busy)
        #expect(ids(row) == ["cmux.continueInBrowser", "cmux.cancelSignIn"])
        #expect(row.note != nil)
        #expect(row.error == nil)
    }

    @Test func aFailedSignInSaysWhyAndOffersSignInAgain() {
        let services = MockAccountsServices()
        services.isSignedInToCmux = false
        services.cmuxSignInState = CmuxAccountState(signedIn: false, failure: "Sign-in timed out. (TIMED_OUT)")
        let row = AccountsModel(services: services).pageState.cmux
        #expect(ids(row) == ["cmux.signIn"])
        #expect(row.statusKind == "attention")
        #expect(row.error?.contains("TIMED_OUT") == true)
    }

    @Test func pageActionsReachTheServices() async {
        let services = MockAccountsServices()
        let model = AccountsModel(services: services)
        for name in ["cmux.signOut", "cmux.signIn", "cmux.cancelSignIn", "cmux.continueInBrowser", "cmux.switchAccount"] {
            let action = AccountsPageAction(action: name, provider: nil, account: nil, secret: nil)
            #expect(action != nil)
            if let action { await model.perform(action) }
        }
        #expect(services.calls.filter { $0.hasPrefix("cmux:") } ==
            ["cmux:signOut", "cmux:signIn", "cmux:cancelSignIn", "cmux:continueInBrowser", "cmux:switchAccount"])
        #expect(AccountsPageAction(action: "cmux.nope", provider: nil, account: nil, secret: nil) == nil)
    }

    @Test func emailsAreMasked() {
        #expect(CmuxAccountState.mask("leo@example.com") == "l…@e…")
        #expect(CmuxAccountState.mask("no-at-sign") == nil)
        #expect(CmuxAccountState.mask(nil) == nil)
    }

    /// Edge ended every popup as canceledLogin (2026-10-19): Automatic signs
    /// in through the default browser unless that browser is Safari.
    @Test func automaticKeepsThePopupForSafariOnly() {
        #expect(!CloudSignInWindow.automatic.opensDefaultBrowser(defaultBrowser: "com.apple.Safari"))
        #expect(CloudSignInWindow.automatic.opensDefaultBrowser(defaultBrowser: "com.microsoft.edgemac"))
        #expect(CloudSignInWindow.automatic.opensDefaultBrowser(defaultBrowser: "com.google.Chrome"))
        #expect(!CloudSignInWindow.automatic.opensDefaultBrowser(defaultBrowser: nil))
        #expect(!CloudSignInWindow.popup.opensDefaultBrowser(defaultBrowser: "com.microsoft.edgemac"))
        #expect(CloudSignInWindow.defaultBrowser.opensDefaultBrowser(defaultBrowser: "com.apple.Safari"))
    }
}
