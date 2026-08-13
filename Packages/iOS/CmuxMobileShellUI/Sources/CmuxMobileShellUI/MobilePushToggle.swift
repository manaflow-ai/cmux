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
    let onReconcile: @MainActor () async -> Bool?
    var mutationClock: any Clock<Duration> = ContinuousClock()

    @State private var mutationTask: Task<Void, Never>?
    @State private var mutationTimeoutTask: Task<Void, Never>?
    @State private var reconciliationTask: Task<Void, Never>?
    @State private var mutationID: UUID?
    @State private var reconciliationID: UUID?
    @State private var previousValue: Bool?
    @State private var retryValue: Bool?
    @State private var showsMutationError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(
                L10n.string(
                    "mobile.notifications.phoneEnabled",
                    defaultValue: "Allow Push Alerts on This iPhone"
                ),
                isOn: binding
            )
            .accessibilityIdentifier("MobileSettingsNotifications")
            .disabled(isUpdating)

            if showsMutationError {
                Text(L10n.string(
                    "mobile.notifications.phoneMutationFailed",
                    defaultValue: "Couldn't update Push Alerts. Check your connection and try again."
                ))
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("MobileSettingsNotificationsError")

                if let retryValue {
                    Button {
                        startMutation(retryValue)
                    } label: {
                        Text(L10n.string(
                            "mobile.notifications.phoneMutationRetry",
                            defaultValue: "Try Again"
                        ))
                    }
                    .accessibilityIdentifier("MobileSettingsNotificationsRetry")
                }
            }
        }
        .onAppear {
            reconcileIfNeeded()
        }
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
        reconciliationTask?.cancel()
        reconciliationTask = nil
        reconciliationID = nil
        showsMutationError = false
        retryValue = nil
        let mutationID = UUID()
        let previous = isEnabled
        self.mutationID = mutationID
        previousValue = previous
        isEnabled = requested
        isUpdating = true
        mutationTask = Task { @MainActor in
            let succeeded = await onChange(requested)
            guard !Task.isCancelled else { return }
            finishMutation(
                id: mutationID,
                requested: requested,
                succeeded: succeeded
            )
        }
        mutationTimeoutTask = Task { @MainActor in
            do {
                try await mutationClock.sleep(for: Self.mutationTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            finishMutation(
                id: mutationID,
                requested: requested,
                succeeded: false,
                cancelOperation: true,
                outcomeUnknown: true
            )
        }
    }

    private func finishMutation(
        id: UUID,
        requested: Bool,
        succeeded: Bool,
        cancelOperation: Bool = false,
        outcomeUnknown: Bool = false
    ) {
        guard mutationID == id else { return }
        if cancelOperation {
            mutationTask?.cancel()
        }
        if !succeeded, !outcomeUnknown, let previousValue {
            isEnabled = previousValue
        }
        if !succeeded {
            showsMutationError = true
            retryValue = requested
        }
        mutationTask = nil
        mutationTimeoutTask?.cancel()
        mutationTimeoutTask = nil
        mutationID = nil
        previousValue = nil
        isUpdating = false
        if outcomeUnknown {
            startReconciliation(for: requested)
        }
    }

    private func cancelMutation() {
        mutationTask?.cancel()
        mutationTimeoutTask?.cancel()
        reconciliationTask?.cancel()
        reconciliationTask = nil
        reconciliationID = nil
        // Cancellation cannot prove that an already-submitted request did not
        // commit. Keep the optimistic value marked unknown until the next
        // appearance asks the owner for its authoritative state.
        if let previousValue {
            if isEnabled != previousValue {
                showsMutationError = true
                retryValue = isEnabled
            }
        }
        mutationTask = nil
        mutationTimeoutTask = nil
        mutationID = nil
        previousValue = nil
        isUpdating = false
    }

    private func startReconciliation(for requested: Bool) {
        let reconciliationID = UUID()
        self.reconciliationID = reconciliationID
        reconciliationTask?.cancel()
        reconciliationTask = Task { @MainActor in
            let authoritative = await onReconcile()
            guard !Task.isCancelled,
                  self.reconciliationID == reconciliationID else { return }
            if let authoritative {
                isEnabled = authoritative
                showsMutationError = authoritative != requested
                retryValue = authoritative == requested ? nil : requested
            }
            reconciliationTask = nil
            self.reconciliationID = nil
        }
    }

    private func reconcileIfNeeded() {
        guard mutationTask == nil, let retryValue, showsMutationError else { return }
        startReconciliation(for: retryValue)
    }
}
#endif
