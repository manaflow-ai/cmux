import CmuxMobileSupport
import SwiftUI

#if os(iOS)
/// Recovery state shown when the team registry cannot provide an authoritative response.
struct DisconnectedRegistryUnavailableView: View {
    let isRefreshing: Bool
    let retry: () -> Void
    let addComputer: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.registry.unavailable.title", defaultValue: "Session Discovery Unavailable"),
                systemImage: "wifi.exclamationmark"
            )
        } description: {
            Text(L10n.string(
                "mobile.registry.unavailable.message",
                defaultValue: "We couldn't load available computers and sessions. Check your connection and try again."
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
#endif
