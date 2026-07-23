#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
import UIKit

extension TaskComposerSheet {
    func announceFailure(_ message: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        AccessibilityNotification.Announcement(message).post()
    }

    func startCompletedOperationReconciliation() {
        guard submitTask == nil, let recovery = activeCompletedOperationRecovery else { return }
        submitTask = Task { @MainActor in
            await reconcileCompletedOperation(recovery.submittedSnapshot)
            submitTask = nil
        }
    }

    private func reconcileCompletedOperation(_ snapshot: MobileTaskSubmissionSnapshot) async {
        submissionPhase = .preparing
        failureText = nil
        await store.refreshWorkspaces()
        guard !Task.isCancelled else {
            submissionPhase = .idle
            return
        }
        let result = await submitTaskComposer(
            snapshot.macDeviceID,
            workspaceCreateSpec(for: snapshot)
        ) {
            submissionPhase = .committed
        }
        submissionPhase = .idle
        guard !Task.isCancelled else { return }
        switch result {
        case .success:
            completeSubmission(snapshot)
        case .failure(.alreadyCompleted):
            completedOperationRecovery?.recordReconciliationStillMissing()
            failureTitleStyle = .taskAccepted
            let message = recoveryFailureMessage(for: .startAgainAvailable)
            failureText = message
            announceFailure(message)
        case .failure(let failure):
            failureTitleStyle = .statusUnconfirmed
            let message = Self.failureMessage(failure)
            failureText = message
            announceFailure(message)
        }
    }

    func confirmStartAgain() {
        guard activeCompletedOperationRecovery?.allowsStartAgain == true else { return }
        completedOperationRecovery = nil
        failureText = nil
        failureTitleStyle = .launchFailed
        startSubmission()
    }

    func completeSubmission(_ snapshot: MobileTaskSubmissionSnapshot) {
        _ = store.completeTaskComposerSubmission(
            snapshot,
            ifSessionGeneration: sessionGeneration
        )
        // Remote success is authoritative. A stale signed-in session may stop
        // local defaults from being saved, but it must not leave a launchable
        // sheet open and invite the user to submit the same task twice.
        completedOperationRecovery = nil
        shouldPersistDraftOnDisappear = false
        dismiss()
    }

    func workspaceCreateSpec(
        for snapshot: MobileTaskSubmissionSnapshot
    ) -> MobileWorkspaceCreateSpec {
        MobileWorkspaceCreateSpec(
            title: snapshot.workspaceTitle,
            workingDirectory: snapshot.trimmedDirectory.isEmpty ? nil : snapshot.trimmedDirectory,
            initialCommand: snapshot.composition.initialCommand,
            initialEnv: snapshot.composition.initialEnv.isEmpty ? nil : snapshot.composition.initialEnv,
            operationID: snapshot.operationID
        )
    }

    func recoveryFailureMessage(for phase: TaskComposerCompletedOperationRecoveryPhase) -> String {
        switch phase {
        case .refreshRequired:
            Self.failureMessage(.alreadyCompleted(hostDisplayName: nil))
        case .startAgainAvailable:
            L10n.string(
                "mobile.taskComposer.recovery.stillMissing",
                defaultValue: "The task is still missing. Refresh again or start it as a new task."
            )
        }
    }
}

struct TaskComposerStartAgainConfirmationModifier: ViewModifier {
    @Binding var isPresented: Bool
    let confirm: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            L10n.string(
                "mobile.taskComposer.recovery.startAgain.title",
                defaultValue: "Start this task again?"
            ),
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            Button(
                L10n.string(
                    "mobile.taskComposer.recovery.startAgain",
                    defaultValue: "Start Again"
                ),
                role: .destructive,
                action: confirm
            )
            Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(
                L10n.string(
                    "mobile.taskComposer.recovery.startAgain.message",
                    defaultValue: "Only continue if the task is not present. Starting again may create a duplicate."
                )
            )
        }
    }
}
#endif
