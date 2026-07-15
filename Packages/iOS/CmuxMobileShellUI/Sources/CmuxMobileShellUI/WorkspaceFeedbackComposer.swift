import CmuxMobileSupport
import SwiftUI

// Release-safe Send Feedback composer. Privileged @manaflow.ai users on an
// active connection ship a diagnostic bundle straight to the paired Mac's
// agent sink; everyone else emails the feedback inbox. Either way the
// submission is stamped with build type + version + device.
struct WorkspaceFeedbackComposer: View {
    @Binding var isPresented: Bool
    @Binding var text: String
    @Binding var email: String
    @Binding var isSubmitting: Bool
    let routesToAgent: Bool
    let explanation: String
    let errorMessage: String?
    let canSubmit: Bool
    let submit: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField(
                    L10n.string("mobile.feedback.placeholder", defaultValue: "What happened?"),
                    text: $text,
                    axis: .vertical
                )
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("MobileFeedbackComposerField")
                if !routesToAgent {
                    TextField(
                        L10n.string("mobile.feedback.emailPlaceholder", defaultValue: "Your email"),
                        text: $email
                    )
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("MobileFeedbackComposerEmailField")
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("MobileFeedbackComposerError")
                }
                Spacer()
            }
            .padding(16)
            .navigationTitle(L10n.string("mobile.feedback.send", defaultValue: "Send Feedback"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.feedback.cancel", defaultValue: "Cancel")) {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        L10n.string("mobile.feedback.sendAction", defaultValue: "Send"),
                        action: submit
                    )
                    .disabled(isSubmitting || !canSubmit)
                    .accessibilityIdentifier("MobileFeedbackComposerSend")
                }
            }
        }
        .presentationDetents([.medium])
    }
}
