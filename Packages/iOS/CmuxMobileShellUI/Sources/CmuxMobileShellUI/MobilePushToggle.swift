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
    @State private var mutationTask: Task<Void, Never>?

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
        .onDisappear {
            mutationTask?.cancel()
            mutationTask = nil
            isUpdating = false
        }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { requested in
                startMutation(requested)
            }
        )
    }

    private func startMutation(_ requested: Bool) {
        guard mutationTask == nil, !isUpdating else { return }
        let previous = isEnabled
        isEnabled = requested
        isUpdating = true
        mutationTask = Task { @MainActor in
            defer {
                mutationTask = nil
                isUpdating = false
            }
            let succeeded = await onChange(requested)
            guard !Task.isCancelled else { return }
            if !succeeded {
                isEnabled = previous
            }
        }
    }
}
#endif
