#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The composer's persistent primary action. Keeping it outside the virtualized
/// scrolling content makes the visible action a stable accessibility element
/// on compact and regular-width layouts.
struct TaskComposerPrimaryAction: View {
    let isSubmitting: Bool
    let isEnabled: Bool
    let templateIcon: String?
    let actionTitle: String
    let progressTitle: String
    let failureText: String?
    let completedOperationRecovery: TaskComposerCompletedOperationRecovery?
    let action: () -> Void
    let refreshCompletedOperation: () -> Void
    let requestStartAgain: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if let failureText {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .accessibilityHidden(true)
                    Text(failureText)
                        .font(.footnote.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            } else {
                Button(action: action) {
                    HStack(spacing: 10) {
                        if isSubmitting {
                            ProgressView()
                        } else if let templateIcon {
                            TaskTemplateIcon(value: templateIcon, size: 18)
                        }
                        Text(isSubmitting ? progressTitle : actionTitle)
                            .fontWeight(.semibold)
                        if !isSubmitting {
                            Image(systemName: "arrow.up.right")
                                .font(.subheadline.weight(.bold))
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.capsule)
                }
                .mobileGlassProminentButton()
                .disabled(isSubmitting || !isEnabled)
                .accessibilityLabel(isSubmitting ? progressTitle : actionTitle)
                .accessibilityHint(TaskComposerSheet.createAccessibilityHint)
                .accessibilityIdentifier("MobileTaskComposerCreateButton")

                Text(
                    L10n.string(
                        "mobile.taskComposer.action.caption",
                        defaultValue: "Creates a workspace and sends your prompt immediately."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: 680)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .sensoryFeedback(.impact(weight: .light), trigger: isSubmitting) { oldValue, newValue in
            !oldValue && newValue
        }
    }
}
#endif
