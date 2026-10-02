#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Shared failure and completed-operation recovery controls for both layouts.
struct TaskComposerFailureRecoveryContent: View {
    let isSubmitting: Bool
    let failureTitle: String
    let failureText: String?
    let completedOperationRecovery: TaskComposerCompletedOperationRecovery?
    let refreshCompletedOperation: () -> Void
    let requestStartAgain: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if let failureText {
                TaskComposerFailureBanner(title: failureTitle, message: failureText)
            }

            if let completedOperationRecovery {
                HStack(spacing: 10) {
                    Button(action: refreshCompletedOperation) {
                        Group {
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Text(
                                    completedOperationRecovery.allowsStartAgain
                                        ? L10n.string(
                                            "mobile.taskComposer.recovery.refreshAgain",
                                            defaultValue: "Refresh Again"
                                        )
                                        : L10n.string(
                                            "mobile.taskComposer.recovery.refresh",
                                            defaultValue: "Refresh Workspaces"
                                        )
                                )
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .mobileGlassProminentButton()
                    .disabled(isSubmitting)
                    .accessibilityHint(TaskComposerSheet.recoveryRefreshAccessibilityHint)
                    .accessibilityIdentifier("MobileTaskComposerRefreshButton")

                    if completedOperationRecovery.allowsStartAgain {
                        Button(
                            L10n.string(
                                "mobile.taskComposer.recovery.startAgain",
                                defaultValue: "Start Again"
                            ),
                            action: requestStartAgain
                        )
                        .mobileGlassButton()
                        .disabled(isSubmitting)
                        .accessibilityHint(TaskComposerSheet.recoveryStartAgainAccessibilityHint)
                        .accessibilityIdentifier("MobileTaskComposerStartAgainButton")
                    }
                }
            }
        }
    }
}
#endif
