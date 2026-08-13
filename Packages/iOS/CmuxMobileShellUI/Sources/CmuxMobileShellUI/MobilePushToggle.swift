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
    @State private var reconciliationTimeoutTask: Task<Void, Never>?
    @State private var mutationID: UUID?
    @State private var reconciliationID: UUID?
    @State private var previousValue: Bool?
    @State private var retryValue: Bool?
    @State private var mutationTimedOut = false
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

                if mutationTask == nil, reconciliationTask == nil, let retryValue {
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
        reconciliationTimeoutTask?.cancel()
        reconciliationTimeoutTask = nil
        reconciliationID = nil
        mutationTimedOut = false
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
            guard self.mutationID == mutationID else { return }
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
            guard self.mutationID == mutationID else { return }
            // Cancellation is only a request. Keep the operation as the
            // owner of the write until it actually returns, then reconcile.
            mutationTimedOut = true
            showsMutationError = true
            retryValue = requested
            mutationTask?.cancel()
            mutationTimeoutTask = nil
        }
    }

    private func finishMutation(
        id: UUID,
        requested: Bool,
        succeeded: Bool
    ) {
        guard mutationID == id else { return }
        let outcomeWasUnknown = mutationTimedOut
        if !succeeded, !outcomeWasUnknown, let previousValue {
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
        mutationTimedOut = false
        isUpdating = false
        if outcomeWasUnknown {
            startReconciliation(for: requested)
        }
    }

    private func cancelMutation() {
        guard mutationTask != nil else {
            mutationTimeoutTask?.cancel()
            mutationTimeoutTask = nil
            reconciliationTask?.cancel()
            reconciliationTimeoutTask?.cancel()
            reconciliationTask = nil
            reconciliationTimeoutTask = nil
            reconciliationID = nil
            return
        }

        // A disappearing view may cancel the task after its request reached
        // the service. Preserve the active operation and let its completion
        // trigger reconciliation, rather than clearing its ownership here.
        mutationTimedOut = true
        showsMutationError = true
        retryValue = isEnabled
        mutationTask?.cancel()
        mutationTimeoutTask?.cancel()
        mutationTimeoutTask = nil
        reconciliationTask?.cancel()
        reconciliationTimeoutTask?.cancel()
        reconciliationTask = nil
        reconciliationTimeoutTask = nil
        reconciliationID = nil
    }

    private func startReconciliation(for requested: Bool) {
        guard reconciliationTask == nil else { return }
        let reconciliationID = UUID()
        self.reconciliationID = reconciliationID
        reconciliationTask = Task { @MainActor in
            let authoritative = await onReconcile()
            guard self.reconciliationID == reconciliationID else { return }
            if !Task.isCancelled, let authoritative {
                isEnabled = authoritative
                showsMutationError = authoritative != requested
                retryValue = authoritative == requested ? nil : requested
            } else if !Task.isCancelled {
                showsMutationError = true
                retryValue = requested
            }
            finishReconciliation(id: reconciliationID)
        }
        reconciliationTimeoutTask = Task { @MainActor in
            do {
                try await mutationClock.sleep(for: Self.mutationTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.reconciliationID == reconciliationID else { return }
            reconciliationTask?.cancel()
            // The authoritative read did not complete by the deadline. Keep
            // the optimistic value marked unknown and offer a retry instead of
            // leaving the control busy forever.
            showsMutationError = true
            retryValue = requested
            reconciliationTask = nil
            reconciliationTimeoutTask = nil
            self.reconciliationID = nil
        }
    }

    private func finishReconciliation(id: UUID) {
        guard reconciliationID == id else { return }
        reconciliationTimeoutTask?.cancel()
        reconciliationTimeoutTask = nil
        reconciliationTask = nil
        reconciliationID = nil
    }

    private func reconcileIfNeeded() {
        guard mutationTask == nil, let retryValue, showsMutationError else { return }
        startReconciliation(for: retryValue)
    }
}
#endif
