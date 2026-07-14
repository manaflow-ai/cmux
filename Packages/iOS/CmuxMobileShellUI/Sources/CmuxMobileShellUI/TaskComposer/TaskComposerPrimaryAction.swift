#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The composer's persistent primary action. Keeping it outside the virtualized
/// form makes the visible action a stable accessibility element while the form
/// scrolls on compact and regular-width layouts.
struct TaskComposerPrimaryAction: View {
    let isSubmitting: Bool
    let isEnabled: Bool
    let failureText: String?
    let completedOperationRecovery: TaskComposerCompletedOperationRecovery?
    let action: () -> Void
    let refreshCompletedOperation: () -> Void
    let requestStartAgain: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if let failureText {
                Text(failureText)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .accessibilityIdentifier("MobileTaskComposerFailure")
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
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
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
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(isSubmitting)
                        .accessibilityHint(TaskComposerSheet.recoveryStartAgainAccessibilityHint)
                        .accessibilityIdentifier("MobileTaskComposerStartAgainButton")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            } else {
                Button(action: action) {
                    Group {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text(L10n.string("mobile.taskComposer.create", defaultValue: "Create"))
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isSubmitting || !isEnabled)
                .accessibilityLabel(
                    isSubmitting
                        ? L10n.string("mobile.taskComposer.creating", defaultValue: "Creating Task")
                        : L10n.string("mobile.taskComposer.create", defaultValue: "Create")
                )
                .accessibilityHint(TaskComposerSheet.createAccessibilityHint)
                .accessibilityIdentifier("MobileTaskComposerCreateButton")
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
        .background(.bar)
        .accessibilityIdentifier("MobileTaskComposerPrimaryAction")
    }
}
#endif
