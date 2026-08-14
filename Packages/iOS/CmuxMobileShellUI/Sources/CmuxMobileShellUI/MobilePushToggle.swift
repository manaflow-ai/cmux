#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Release phone-push toggle, shared with its diagnostic test harness.
struct MobilePushToggle: View {
    @Binding var isEnabled: Bool
    /// Applies an intent and returns the resulting enabled state.
    let resolveEnabledState: @MainActor (Bool) async -> Bool
    @State private var mutationTask: Task<Void, Never>?
    @State private var pendingRequest: Bool?

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
                pendingRequest = requested
                startMutationWorkerIfNeeded()
            }
        )
    }

    @MainActor
    private func startMutationWorkerIfNeeded() {
        guard mutationTask == nil else { return }
        mutationTask = Task { @MainActor in
            while let requested = pendingRequest {
                pendingRequest = nil
                let resolved = await resolveEnabledState(requested)
                if pendingRequest == resolved {
                    pendingRequest = nil
                }
                if let pendingRequest {
                    isEnabled = pendingRequest
                } else {
                    isEnabled = resolved
                }
            }
            mutationTask = nil
        }
    }
}
#endif
