@testable import CmuxNextApp
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextFocusUI
@testable import CmuxNextMacScreen
import Testing

/// Lawrence, msg 3790: "everywhere we say sign in, we need to have a button for signing in". A
/// refusal toast that says to sign in to cmux, Mac Screen's signed-out card and home page, and the
/// Automations page's signed-out line each offer the one Sign In, which runs the app's sign-in.
@MainActor
@Suite struct SignInOfferTests {
    /// A Cloud refusal while signed out offers Sign In, and its click runs the sign-in once.
    @Test(arguments: [CloudStrings.signInFirst, CloudStrings.signInToContinue])
    func signInReasonOffersSignIn(_ reason: String) throws {
        var signIns = 0
        let offer = CmuxSignInOffer(isSignedIn: { false }) { signIns += 1 }
        let signIn = try #require(offer.offer(for: reason))
        signIn()
        #expect(signIns == 1)
    }

    /// Any other reason, or a sign-in reason seen while signed in already, offers nothing.
    @Test func otherReasonsAndSignedInOfferNothing() {
        let signedOut = CmuxSignInOffer(isSignedIn: { false }) {}
        #expect(signedOut.offer(for: "Not enough room to split this column") == nil)
        let signedIn = CmuxSignInOffer(isSignedIn: { true }) {}
        #expect(signedIn.offer(for: CloudStrings.signInFirst) == nil)
    }

    /// The refusal toast carries Sign In as its action for a sign-in reason, and nothing else for others.
    @Test func refusalToastOffersSignIn() throws {
        var signIns = 0
        let offer = CmuxSignInOffer(isSignedIn: { false }) { signIns += 1 }
        let hud = RefusalHUD(toasts: CmuxToastCenter())
        hud.signInOffer = { offer.offer(for: $0) }

        let (toast, run) = hud.toast(for: CloudStrings.signInFirst)
        #expect(toast.message == CloudStrings.signInFirst)
        #expect(toast.action?.title == SignInButton.defaultTitle)
        let signIn = try #require(run)
        signIn()
        #expect(signIns == 1)

        let (plain, none) = hud.toast(for: "Not enough room to split this column")
        #expect(plain.action == nil)
        #expect(none == nil)
    }

    /// Mac Screen's home page, signed out with a valid hub, shows its note with Sign In; a bad hub
    /// address is a note to fix, with no Sign In.
    @Test func macScreenHomeSignedOutOffersSignIn() {
        guard case .signedOut = MacScreenHomeSnapshot.setupDevices(configured: true) else {
            Issue.record("signed out showed no Sign In")
            return
        }
        guard case .note = MacScreenHomeSnapshot.setupDevices(configured: false) else {
            Issue.record("a bad hub address offered Sign In")
            return
        }
    }
}
