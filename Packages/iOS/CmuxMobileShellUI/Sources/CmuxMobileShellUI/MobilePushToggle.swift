#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Release phone-push toggle, shared with its diagnostic test harness.
struct MobilePushToggle: View {
    @Binding var isEnabled: Bool
    /// Commits an app-lifetime intent after the binding changes immediately.
    let applyEnabledIntent: @MainActor (Bool) -> Void

    var body: some View {
        Toggle(
            L10n.string(
                "mobile.notifications.phoneEnabled",
                defaultValue: "Allow Push Alerts on This iPhone"
            ),
            isOn: binding
        )
        .accessibilityIdentifier("MobileSettingsNotifications")
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { requested in
                isEnabled = requested
                applyEnabledIntent(requested)
            }
        )
    }
}
#endif
