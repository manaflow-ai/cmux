#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The phone preference is owned by ``MobilePushCoordinator``. This view only
/// renders the binding, so leaving Settings cannot cancel or roll back a
/// requested opt-out.
struct MobilePushToggle: View {
    @Binding var isEnabled: Bool
    let isUpdating: Bool

    var body: some View {
        Toggle(
            L10n.string(
                "mobile.notifications.phoneEnabled",
                defaultValue: "Allow Push Alerts on This iPhone"
            ),
            isOn: $isEnabled
        )
        .accessibilityIdentifier("MobileSettingsNotifications")
        .disabled(isUpdating)
    }
}
#endif
