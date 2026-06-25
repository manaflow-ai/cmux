import CmuxMobileSupport
import SwiftUI

struct AuthenticatedUserScopeUnavailableView: View {
    let retry: () -> Void
    let signOut: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.authScope.unavailableTitle", defaultValue: "Account unavailable"),
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
        } description: {
            Text(L10n.string(
                "mobile.authScope.unavailableDescription",
                defaultValue: "cmux could not finish loading your account. Check your connection, then retry."
            ))
        } actions: {
            Button(action: retry) {
                Text(L10n.string("mobile.common.retry", defaultValue: "Retry"))
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("MobileAuthScopeRetry")

            Button(action: signOut) {
                Text(L10n.string("mobile.signOut", defaultValue: "Sign Out"))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("MobileAuthScopeSignOut")
        }
        .accessibilityIdentifier("MobileAuthScopeUnavailable")
    }
}
