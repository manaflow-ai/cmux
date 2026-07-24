#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The composer's persistent primary action. Keeping it outside the virtualized
/// scrolling content makes the visible action a stable accessibility element
/// on compact and regular-width layouts.
struct TaskComposerPrimaryAction: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let isSubmitting: Bool
    let isEnabled: Bool
    let templateIcon: String?
    let actionTitle: String
    let progressTitle: String
    let caption: String
    let failureTitle: String
    let failureText: String?
    let completedOperationRecovery: TaskComposerCompletedOperationRecovery?
    let action: () -> Void
    let refreshCompletedOperation: () -> Void
    let requestStartAgain: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if failureText != nil || completedOperationRecovery != nil {
                TaskComposerFailureRecoveryContent(
                    isSubmitting: isSubmitting,
                    failureTitle: failureTitle,
                    failureText: failureText,
                    completedOperationRecovery: completedOperationRecovery,
                    refreshCompletedOperation: refreshCompletedOperation,
                    requestStartAgain: requestStartAgain
                )
            }

            if completedOperationRecovery == nil {
                Button(action: action) {
                    HStack(spacing: 10) {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 28, height: 28)
                        } else if let templateIcon {
                            TaskTemplateIcon(value: templateIcon, size: 18)
                                .frame(width: 28, height: 28)
                                .background(Color.white.opacity(0.14), in: Circle())
                        }
                        Text(isSubmitting ? progressTitle : actionTitle)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.capsule)
                }
                .mobileGlassProminentButton()
                .disabled(isSubmitting || !isEnabled)
                .accessibilityLabel(isSubmitting ? progressTitle : actionTitle)
                .accessibilityHint(TaskComposerSheet.createAccessibilityHint)
                .accessibilityIdentifier("MobileTaskComposerCreateButton")

                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("MobileTaskComposerActionCaption")
            }
        }
        // Persistent chrome must stay compact even when content text uses the
        // largest accessibility categories. Accessibility 1 remains larger
        // than standard text while preserving enough prompt canvas to work.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .frame(maxWidth: 680)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [.clear, Color.accentColor.opacity(0.24), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
            .accessibilityHidden(true)
        }
        .animation(
            accessibilityReduceMotion ? nil : .snappy(duration: 0.22),
            value: isEnabled
        )
        .sensoryFeedback(.impact(weight: .light), trigger: isSubmitting) { oldValue, newValue in
            !oldValue && newValue
        }
    }
}
#endif
