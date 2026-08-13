#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The phone push preference is persisted asynchronously, so update the
/// control optimistically and roll it back only when the mutation fails.
/// Keeping this binding shared prevents release and diagnostic settings from
/// drifting into different interaction behavior.
struct MobilePushToggle: View {
    private static let mutationTimeout: Duration = .seconds(30)

    @Binding var isEnabled: Bool
    @Binding var isUpdating: Bool
    let onChange: @MainActor (Bool) async -> Bool
    var mutationClock: any Clock<Duration> = ContinuousClock()

    @State private var mutationTask: Task<Void, Never>?
    @State private var mutationTimeoutTask: Task<Void, Never>?
    @State private var mutationID: UUID?
    @State private var previousValue: Bool?

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
            cancelMutation()
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
        let mutationID = UUID()
        let previous = isEnabled
        self.mutationID = mutationID
        previousValue = previous
        isEnabled = requested
        isUpdating = true
        mutationTask = Task { @MainActor in
            let succeeded = await onChange(requested)
            guard !Task.isCancelled else { return }
            finishMutation(id: mutationID, succeeded: succeeded)
        }
        mutationTimeoutTask = Task { @MainActor in
            do {
                try await mutationClock.sleep(for: Self.mutationTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            finishMutation(id: mutationID, succeeded: false, cancelOperation: true)
        }
    }

    private func finishMutation(
        id: UUID,
        succeeded: Bool,
        cancelOperation: Bool = false
    ) {
        guard mutationID == id else { return }
        if cancelOperation {
            mutationTask?.cancel()
        }
        if !succeeded, let previousValue {
            isEnabled = previousValue
        }
        mutationTask = nil
        mutationTimeoutTask?.cancel()
        mutationTimeoutTask = nil
        mutationID = nil
        previousValue = nil
        isUpdating = false
    }

    private func cancelMutation() {
        mutationTask?.cancel()
        mutationTimeoutTask?.cancel()
        if let previousValue {
            isEnabled = previousValue
        }
        mutationTask = nil
        mutationTimeoutTask = nil
        mutationID = nil
        previousValue = nil
        isUpdating = false
    }
}
#endif
