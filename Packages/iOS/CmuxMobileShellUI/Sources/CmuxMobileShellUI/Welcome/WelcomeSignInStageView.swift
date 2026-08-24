#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The tour's embedded sign-in stage.
///
/// Sign-in is deferred to this point per the HIG (people first experienced
/// the product), and the copy explains what the account is for: it is the
/// rendezvous that lets the phone find Macs without any network setup. The
/// actual controls are the shared ``SignInView`` in embedded chrome; when
/// authentication completes the tour container advances on its own.
struct WelcomeSignInStageView: View {
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text(L10n.string(
                    "mobile.welcome.signIn.title",
                    defaultValue: "One account links both devices"
                ))
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
                Text(L10n.string(
                    "mobile.welcome.signIn.subtitle",
                    defaultValue: "Sign in with the same account you use for cmux on your Mac. That is how your phone finds it. No addresses, no port forwarding."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            SignInView(usesStandaloneChrome: false)
        }
        .accessibilityIdentifier("MobileWelcomeStage-signIn")
    }
}
#endif
