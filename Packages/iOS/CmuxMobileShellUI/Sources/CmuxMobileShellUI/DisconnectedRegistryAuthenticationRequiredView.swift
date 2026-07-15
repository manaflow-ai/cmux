import CmuxMobileSupport
import SwiftUI

#if os(iOS)
/// Recovery state shown when registry authorization rejects the current account or team.
struct DisconnectedRegistryAuthenticationRequiredView: View {
    let isRefreshing: Bool
    let retry: () -> Void
    let switchAccount: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.handoff.auth.title", defaultValue: "Session Discovery Unavailable"),
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
        } description: {
            Text(L10n.string(
                "mobile.handoff.auth.message",
                defaultValue: "We couldn't verify your cmux account for session discovery. Try again, or sign out and sign back in."
            ))
        } actions: {
            Button(action: retry) {
                Text(L10n.string("mobile.common.retry", defaultValue: "Retry"))
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRefreshing)
            Button(action: switchAccount) {
                Text(L10n.string(
                    "mobile.recovery.switchAccount",
                    defaultValue: "Sign Out & Switch Account"
                ))
            }
            .accessibilityIdentifier("MobileRegistryReauthSignOut")
        }
    }
}
#endif
