#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Shared phone-push toggle used by release and diagnostic Settings.
struct MobilePushToggle: View {
    @Binding var isEnabled: Bool
    @Binding var isUpdating: Bool
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
        .disabled(isUpdating)
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { requested in
                guard !isUpdating else { return }
                let previous = isEnabled
                isUpdating = true
                Task { @MainActor in
                    defer { isUpdating = false }
                    if !(await onChange(requested)) {
                        isEnabled = previous
                    }
                }
            }
        )
    }
}
#endif
