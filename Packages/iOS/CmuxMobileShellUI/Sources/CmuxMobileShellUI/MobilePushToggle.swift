#if os(iOS)
import CmuxMobileSupport
import Foundation
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

    @State private var mutationSequencer = MobilePushMutationSequencer()
    @State private var currentAttempt: MobilePushMutationAttempt?
    @State private var currentReconciliation: MobilePushReconciliationAttempt?
    @State private var mutationTimeoutTask: Task<Void, Never>?
    @State private var previousValue: Bool?
    @State private var retryValue: Bool?
    @State private var queuedMutationValue: Bool?
    @State private var mutationGeneration = 0
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

                if currentReconciliation == nil, let retryValue {
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
            cancelCurrentOperation()
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
        guard !isUpdating else { return }
        if currentReconciliation != nil {
            // Let the authoritative read settle before capturing the rollback
            // value for this write. The request remains optimistic in the UI,
            // but the actual operation is queued behind that read.
            queuedMutationValue = requested
            isEnabled = requested
            isUpdating = true
            showsMutationError = false
            retryValue = nil
            return
        }
        beginMutation(requested)
    }

    private func beginMutation(_ requested: Bool) {
        mutationGeneration += 1
        let generation = mutationGeneration
        invalidateCurrentReconciliation()
        mutationTimeoutTask?.cancel()
        mutationTimeoutTask = nil

        let attempt = MobilePushMutationAttempt(requested: requested)
        currentAttempt = attempt
        previousValue = isEnabled
        isEnabled = requested
        isUpdating = true
        showsMutationError = false
        retryValue = nil

        let task = mutationSequencer.enqueue(
            { await self.onChange(requested) },
            completion: { succeeded in
                self.finishMutation(
                    attempt: attempt,
                    generation: generation,
                    succeeded: succeeded
                )
            }
        )
        attempt.task = task
        mutationTimeoutTask = Task { @MainActor in
            do {
                try await mutationClock.sleep(for: Self.mutationTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled, self.currentAttempt === attempt else { return }
            timeoutMutation(attempt, generation: generation)
        }
    }

    private func timeoutMutation(
        _ attempt: MobilePushMutationAttempt,
        generation: Int
    ) {
        guard currentAttempt === attempt else { return }
        attempt.didTimeout = true
        showsMutationError = true
        retryValue = attempt.requested
        queuedMutationValue = nil
        // The request may still finish and commit, so its task remains in the
        // sequencer. Releasing the binding keeps the UI recoverable while every
        // later write waits behind this one.
        isUpdating = false
        mutationTimeoutTask = nil
        attempt.task?.cancel()
        currentAttempt = nil
        previousValue = nil
        enqueueReconciliation(for: attempt.requested, generation: generation)
    }

    private func finishMutation(
        attempt: MobilePushMutationAttempt,
        generation: Int,
        succeeded: Bool
    ) {
        if attempt.didTimeout {
            // The reconciliation was reserved at timeout, immediately after
            // this write in the sequencer. A late completion only closes the
            // attempt; it must never overwrite a newer UI generation.
            return
        }
        guard currentAttempt === attempt,
              generation == mutationGeneration else { return }
        if !succeeded, let previousValue {
            isEnabled = previousValue
        }
        if !succeeded {
            showsMutationError = true
            retryValue = attempt.requested
        }
        mutationTimeoutTask?.cancel()
        mutationTimeoutTask = nil
        currentAttempt = nil
        self.previousValue = nil
        isUpdating = false
    }

    private func cancelCurrentOperation() {
        if let attempt = currentAttempt {
            timeoutMutation(attempt, generation: mutationGeneration)
        }
        mutationTimeoutTask?.cancel()
        mutationTimeoutTask = nil
        // Queued operations remain in the sequencer. Their callbacks are
        // generation-checked, so a disappearing view cannot race a later read
        // or write into visible state.
        invalidateCurrentReconciliation()
    }

    private func enqueueReconciliation(for requested: Bool, generation: Int) {
        let reconciliation = MobilePushReconciliationAttempt(
            requested: requested,
            generation: generation
        )
        currentReconciliation = reconciliation
        let task = mutationSequencer.enqueue(
            { await self.onReconcile() },
            completion: { authoritative in
                self.finishReconciliation(
                    reconciliation,
                    authoritative: authoritative
                )
            }
        )
        reconciliation.task = task
        reconciliation.timeoutTask = Task { @MainActor in
            do {
                try await mutationClock.sleep(for: Self.mutationTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.currentReconciliation === reconciliation else { return }
            reconciliation.task?.cancel()
            self.currentReconciliation = nil
            reconciliation.timeoutTask = nil
            self.showsMutationError = true
            self.isUpdating = false
            self.retryValue = self.queuedMutationValue ?? requested
            self.queuedMutationValue = nil
        }
    }

    private func finishReconciliation(
        _ reconciliation: MobilePushReconciliationAttempt,
        authoritative: Bool?
    ) {
        guard currentReconciliation === reconciliation else { return }
        reconciliation.timeoutTask?.cancel()
        reconciliation.timeoutTask = nil
        currentReconciliation = nil
        guard reconciliation.generation == mutationGeneration else { return }
        if let authoritative {
            isEnabled = authoritative
            if let queuedMutationValue {
                self.queuedMutationValue = nil
                previousValue = authoritative
                beginMutation(queuedMutationValue)
                return
            }
            showsMutationError = authoritative != reconciliation.requested
            retryValue = authoritative == reconciliation.requested
                ? nil
                : reconciliation.requested
        } else {
            showsMutationError = true
            retryValue = queuedMutationValue ?? reconciliation.requested
        }
    }

    private func invalidateCurrentReconciliation() {
        currentReconciliation?.timeoutTask?.cancel()
        currentReconciliation = nil
        queuedMutationValue = nil
    }

    private func reconcileIfNeeded() {
        guard currentAttempt == nil,
              currentReconciliation == nil,
              let retryValue,
              showsMutationError else { return }
        enqueueReconciliation(
            for: retryValue,
            generation: mutationGeneration
        )
    }
}
#endif
