import CmuxMobileSupport
import SwiftUI

#if os(iOS)
struct DisconnectedRegistryUnavailableView: View {
    let isRefreshing: Bool
    let retry: () -> Void
    let addComputer: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.handoff.failure.title", defaultValue: "Couldn't Continue Session"),
                systemImage: "wifi.exclamationmark"
            )
        } description: {
            Text(L10n.string(
                "mobile.handoff.failure.message",
                defaultValue: "The session may have ended or its computer may be offline. Refresh and try again."
            ))
        } actions: {
            Button(action: retry) {
                Text(L10n.string("mobile.common.retry", defaultValue: "Retry"))
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRefreshing)
            Button(action: addComputer) {
                Text(L10n.string("mobile.computers.add", defaultValue: "Add Computer"))
            }
        }
    }
}

struct DisconnectedRegistryAuthenticationRequiredView: View {
    let switchAccount: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.settings.account", defaultValue: "Account"),
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
        } description: {
            Text(L10n.string(
                "mobile.recovery.accountMismatch",
                defaultValue: "This computer is signed in to a different cmux account. Sign out and sign back in with that account."
            ))
        } actions: {
            Button(action: switchAccount) {
                Text(L10n.string(
                    "mobile.recovery.switchAccount",
                    defaultValue: "Sign Out & Switch Account"
                ))
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("MobileRegistryReauthSignOut")
        }
    }
}
#endif
