#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Settings row that erases every piece of cmux data on this device so the app
/// behaves like a fresh install. It never deletes server-side data.
struct MobileSettingsResetSection: View {
    @Environment(\.mobileResetLocalData) private var resetLocalData
    @State private var showsConfirmation = false

    var body: some View {
        if let resetLocalData {
            Section {
                Button(role: .destructive) {
                    showsConfirmation = true
                } label: {
                    Label(
                        L10n.string(
                            "mobile.settings.resetLocalData",
                            defaultValue: "Erase All Data on This Device"
                        ),
                        systemImage: "arrow.counterclockwise.circle"
                    )
                }
                .accessibilityIdentifier("MobileSettingsResetLocalData")
            } header: {
                Text(L10n.string("mobile.settings.resetLocalData.header", defaultValue: "Reset"))
            } footer: {
                Text(L10n.string(
                    "mobile.settings.resetLocalData.footer",
                    defaultValue: "Signs out and removes all cmux data stored on this device, including saved computers, keys, settings, and caches, so cmux starts like a new install. Your cmux account and the data stored in cmux, cmux Cloud, and on your computers are not deleted."
                ))
            }
            .alert(
                L10n.string(
                    "mobile.settings.resetLocalData.confirm.title",
                    defaultValue: "Erase all cmux data on this device?"
                ),
                isPresented: $showsConfirmation
            ) {
                Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), role: .cancel) {}
                Button(
                    L10n.string("mobile.settings.resetLocalData.confirm.action", defaultValue: "Erase"),
                    role: .destructive
                ) {
                    resetLocalData()
                }
            } message: {
                Text(L10n.string(
                    "mobile.settings.resetLocalData.confirm.message",
                    defaultValue: "You will be signed out, and saved computers, keys, settings, and caches will be removed from this device. This can’t be undone. Nothing is deleted from your cmux account or from cmux servers."
                ))
            }
        }
    }
}
#endif
