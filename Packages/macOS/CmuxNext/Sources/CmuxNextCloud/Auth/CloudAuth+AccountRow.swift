import Foundation

// What cmux's own row of Settings > Accounts reads from Cloud auth
// (CmuxNextAccounts.CmuxAccountSource; the App declares the conformance).
extension CloudAuth {
    /// The signed-in person's email; the row masks it.
    public var accountEmail: String? { user?.primaryEmail }
    /// The signed-in person's name, when there is no email to mask.
    public var accountName: String? { user?.displayName }
    /// A sign-in is in progress (its popup or browser page is open).
    public var isSigningIn: Bool { browserSignIn.isPresentingSignIn }
    /// The sign-in waits in the default browser, or the popup has been open a while.
    public var signInWaitsInBrowser: Bool { browserSignIn.signInIsSlow }
    /// The last sign-in failed (its reason and detail stay in the flow's log).
    public var signInFailed: Bool { browserSignIn.lastFailure != nil }
}
