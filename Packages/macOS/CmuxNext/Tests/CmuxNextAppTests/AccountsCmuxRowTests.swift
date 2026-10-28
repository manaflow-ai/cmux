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

    /// The reason and its diagnostic code stay in the log, not on screen.
    @Test func aFailedSignInSaysSoAndOffersSignInAgain() {
        let services = MockAccountsServices()
        services.isSignedInToCmux = false
        services.cmuxSignInState = CmuxAccountState(signedIn: false, failed: true)
        let row = AccountsModel(services: services).pageState.cmux
        #expect(ids(row) == ["cmux.signIn"])
        #expect(row.statusKind == "attention")
        #expect(row.error == "Sign-in did not finish. Try again.")
    }

    /// Switch Account runs while signed in: the row shows its progress with
    /// the current account, and Cancel.
    @Test func aSwitchInProgressShowsProgressWithTheCurrentAccount() {
        let services = MockAccountsServices()
        services.cmuxSignInState = CmuxAccountState(signedIn: false, signingIn: true)
        let row = AccountsModel(services: services).pageState.cmux
        #expect(row.status == "Signing in…")
        #expect(row.detail == "d…@e…")
        #expect(row.busy)
        #expect(ids(row) == ["cmux.continueInBrowser", "cmux.cancelSignIn"])
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

    /// The Debug Settings choice maps onto Cloud's window by raw value.
    @Test func everySignInWindowChoiceNamesACloudWindow() {
        #expect(SignInWindowChoice.allCases.map(\.rawValue) == CloudSignInWindow.allCases.map(\.rawValue))
        #expect(AccountTunables.signInWindow.value == .automatic)
    }

    @Test func theRowReadsCloudAuthThroughItsSource() {
        let source = FakeCmuxAccountSource()
        source.isSigningIn = true
        source.signInWaitsInBrowser = true
        #expect(CmuxAccountState(source) == CmuxAccountState(signedIn: false, signingIn: true, waitingForBrowser: true))
        // The sign-in finishes: Cloud auth is signed in and no longer signing in.
        source.isSigningIn = false
        source.signInWaitsInBrowser = false
        source.isSignedIn = true
        source.accountEmail = "leo@example.com"
        #expect(CmuxAccountState(source) == CmuxAccountState(signedIn: true, label: "l…@e…"))
        // Switch Account signs in again while signed in; the row shows both.
        source.isSigningIn = true
        #expect(CmuxAccountState(source) == CmuxAccountState(signedIn: true, label: "l…@e…", signingIn: true))
    }

    @Test func gesturesRunTheSourcesSignInAndTheAppsSignOut() async {
        let source = FakeCmuxAccountSource()
        var signedOut = false, refreshes = 0
        for action in [CmuxAccountAction.switchAccount, .cancelSignIn, .continueInBrowser, .signOut] {
            source.run(action, signOut: { signedOut = true }, refresh: { refreshes += 1 })
        }
        for _ in 0..<200 where refreshes < 2 { await Task.yield() }
        #expect(source.calls == ["begin:true", "cancel", "continue"])
        #expect(signedOut)
        #expect(refreshes == 2)
    }
}

/// Cloud auth's account surface, recorded.
@MainActor
private final class FakeCmuxAccountSource: CmuxAccountSource {
    var isSignedIn = false
    var accountEmail: String?
    var accountName: String?
    var isSigningIn = false
    var signInWaitsInBrowser = false
    var signInFailed = false
    var calls: [String] = []

    func beginSignIn(selectAccount: Bool) -> Task<Bool, Never> {
        calls.append("begin:\(selectAccount)")
        return Task { true }
    }

    func cancelSignIn() { calls.append("cancel") }

    func continueSignInInBrowser() -> Bool {
        calls.append("continue")
        return true
    }
}
