#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Release phone-push toggle, shared with its diagnostic test harness.
struct MobilePushToggle: View {
    @Binding var isEnabled: Bool
    let onChange: @MainActor (Bool) async -> Bool

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
                let previous = isEnabled
                isEnabled = requested
                Task { @MainActor in
                    let succeeded = await onChange(requested)
                    guard isEnabled == requested else { return }
                    if !succeeded {
                        isEnabled = previous
                    }
                }
            }
        )
    }
}
#endif
