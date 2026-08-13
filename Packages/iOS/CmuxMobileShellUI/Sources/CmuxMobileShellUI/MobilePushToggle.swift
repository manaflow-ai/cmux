#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The phone push preference is persisted asynchronously, so update the
/// control optimistically and roll it back only when the mutation fails.
/// Keeping this binding shared prevents release and diagnostic settings from
/// drifting into different interaction behavior.
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
                isEnabled = requested
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
