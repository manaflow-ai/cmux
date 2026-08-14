#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Release phone-push toggle, shared with its diagnostic test harness.
struct MobilePushToggle: View {
    @Binding var isEnabled: Bool
    let onChange: @MainActor (Bool) async -> Bool
    @State private var mutationTask: Task<Void, Never>?
    @State private var pendingRequest: Bool?
    @State private var confirmedValue: Bool?

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
                if mutationTask == nil {
                    confirmedValue = isEnabled
                }
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
                let fallback = confirmedValue ?? isEnabled
                let succeeded = await onChange(requested)
                if succeeded {
                    confirmedValue = requested
                    if pendingRequest == requested {
                        pendingRequest = nil
                    }
                } else if pendingRequest == nil, isEnabled == requested {
                    isEnabled = fallback
                }
            }
            mutationTask = nil
            confirmedValue = nil
        }
    }
}
#endif
