import CmuxFoundation
public import SwiftUI
import AppKit

/// Modal feedback composer presented from the sidebar help menu.
///
/// Collects an email plus message and optional image attachments, submits them
/// through ``FeedbackComposerClient``, and renders submission/success/error
/// state inline. Self-contained: it owns all of its transient `@State` and only
/// depends on the `CmuxFeedback` domain package.
public struct SidebarFeedbackComposerSheet: View {
    private static let formMaxHeight: CGFloat = 560
    private static let settings = FeedbackComposerSettings()

    @AppStorage(SidebarFeedbackComposerSheet.settings.storedEmailKey) private var email = ""
    @Environment(\.dismiss) private var dismiss

    @State private var message = ""
    @State private var attachments: [FeedbackComposerAttachment] = []
    @State private var isSubmitting = false
    @State private var submissionErrorMessage: String?
    @State private var didSend = false

    /// Explicit public initializer: the implicit memberwise init is not visible
    /// across the module boundary now that this type lives in a package.
    public init() {}

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        isValidEmail(email) &&
            !trimmedMessage.isEmpty &&
            message.count <= Self.settings.maxMessageLength &&
            !isSubmitting &&
            !didSend
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "sidebar.help.feedback.title", defaultValue: "Send Feedback", bundle: .module))
                .cmuxFont(.title3, weight: .semibold)

            if didSend {
                successView
            } else {
                ScrollView {
                    formView
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 4)
                }
                .frame(maxHeight: Self.formMaxHeight)
            }
        }
        .padding(20)
        .frame(width: 520)
        .accessibilityIdentifier("SidebarFeedbackDialog")
    }

    private var successView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "sidebar.help.feedback.successTitle", defaultValue: "Thanks for the feedback.", bundle: .module))
                .cmuxFont(.headline)
            Text(
                String(
                    localized: "sidebar.help.feedback.successBody",
                    defaultValue: "You can also reach us at founders@manaflow.com.",
                    bundle: .module
                )
            )
            .cmuxFont(size: 12)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

            HStack {
                Spacer()
                Button(String(localized: "sidebar.help.feedback.done", defaultValue: "Done", bundle: .module)) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                String(
                    localized: "sidebar.help.feedback.note",
                    defaultValue: "A human will read this! You can also reach us at founders@manaflow.com.",
                    bundle: .module
                )
            )
            .cmuxFont(size: 12)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "sidebar.help.feedback.email", defaultValue: "Your Email", bundle: .module))
                    .cmuxFont(size: 12, weight: .medium)
                TextField(
                    String(localized: "sidebar.help.feedback.emailPlaceholder", defaultValue: "you@example.com", bundle: .module),
                    text: $email
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(String(localized: "sidebar.help.feedback.email", defaultValue: "Your Email", bundle: .module))
                .accessibilityIdentifier("SidebarFeedbackEmailField")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(localized: "sidebar.help.feedback.message", defaultValue: "Message", bundle: .module))
                        .cmuxFont(size: 12, weight: .medium)
                    Spacer(minLength: 0)
                    Text("\(message.count)/\(Self.settings.maxMessageLength)")
                        .cmuxFont(size: 11)
                        .foregroundStyle(
                            message.count > Self.settings.maxMessageLength
                                ? Color.red
                                : Color.secondary
                        )
                }

                FeedbackComposerMessageEditor(
                    text: $message,
                    placeholder: String(
                        localized: "sidebar.help.feedback.messagePlaceholder",
                        defaultValue: "Share feedback, feature requests, or issues.",
                        bundle: .module
                    ),
                    accessibilityLabel: String(localized: "sidebar.help.feedback.message", defaultValue: "Message", bundle: .module),
                    accessibilityIdentifier: "SidebarFeedbackMessageEditor"
                )
                .frame(minHeight: 180)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button {
                        chooseAttachments()
                    } label: {
                        Label(
                            String(localized: "sidebar.help.feedback.attachImages", defaultValue: "Attach Images", bundle: .module),
                            systemImage: "paperclip"
                        )
                    }
                    .accessibilityIdentifier("SidebarFeedbackAttachButton")

                    Text(
                        String(
                            localized: "sidebar.help.feedback.attachmentsHint",
                            defaultValue: "Up to 10 images.",
                            bundle: .module
                        )
                    )
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
                }

                if attachments.isEmpty == false {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(attachments) { attachment in
                            HStack(spacing: 8) {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                                Text(attachment.fileName)
                                    .cmuxFont(size: 12)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                Text(attachment.displaySize)
                                    .cmuxFont(size: 11)
                                    .foregroundStyle(.secondary)
                                Button(
                                    String(localized: "sidebar.help.feedback.removeAttachment", defaultValue: "Remove", bundle: .module)
                                ) {
                                    removeAttachment(attachment)
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                }
            }

            if let submissionErrorMessage, submissionErrorMessage.isEmpty == false {
                Text(submissionErrorMessage)
                    .cmuxFont(size: 12)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(String(localized: "sidebar.help.feedback.cancel", defaultValue: "Cancel", bundle: .module)) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    Task { await submitFeedback() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(String(localized: "sidebar.help.feedback.send", defaultValue: "Send", bundle: .module))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
                .accessibilityIdentifier("SidebarFeedbackSendButton")
            }
        }
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.title = String(
            localized: "sidebar.help.feedback.attachImages.title",
            defaultValue: "Attach Images",
            bundle: .module
        )
        panel.prompt = String(
            localized: "sidebar.help.feedback.attachImages.prompt",
            defaultValue: "Attach",
            bundle: .module
        )

        guard panel.runModal() == .OK else { return }

        var updatedAttachments = attachments
        var knownPaths = Set(updatedAttachments.map(\.standardizedPath))
        var firstIssue: String?

        for url in panel.urls {
            let normalizedPath = url.standardizedFileURL.path
            if knownPaths.contains(normalizedPath) {
                continue
            }
            if updatedAttachments.count >= Self.settings.maxAttachmentCount {
                firstIssue = String(
                    localized: "sidebar.help.feedback.tooManyImages",
                    defaultValue: "You can attach up to 10 images.",
                    bundle: .module
                )
                break
            }

            guard let attachment = try? FeedbackComposerAttachment(url: url) else {
                firstIssue = String(
                    localized: "sidebar.help.feedback.invalidImageSelection",
                    defaultValue: "One of the selected files could not be attached.",
                    bundle: .module
                )
                continue
            }
            updatedAttachments.append(attachment)
            knownPaths.insert(normalizedPath)
        }

        attachments = updatedAttachments
        submissionErrorMessage = firstIssue
    }

    private func removeAttachment(_ attachment: FeedbackComposerAttachment) {
        attachments.removeAll { $0.id == attachment.id }
        submissionErrorMessage = nil
    }

    private func submitFeedback() async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = trimmedMessage

        guard isValidEmail(trimmedEmail) else {
            submissionErrorMessage = String(
                localized: "sidebar.help.feedback.invalidEmail",
                defaultValue: "Enter a valid email address.",
                bundle: .module
            )
            return
        }

        guard normalizedMessage.isEmpty == false else {
            submissionErrorMessage = String(
                localized: "sidebar.help.feedback.emptyMessage",
                defaultValue: "Enter a message before sending.",
                bundle: .module
            )
            return
        }

        guard message.count <= Self.settings.maxMessageLength else {
            submissionErrorMessage = String(
                localized: "sidebar.help.feedback.messageTooLong",
                defaultValue: "Your message is too long.",
                bundle: .module
            )
            return
        }

        await MainActor.run {
            email = trimmedEmail
            submissionErrorMessage = nil
            isSubmitting = true
        }

        do {
            try await FeedbackComposerClient(settings: Self.settings).submit(
                email: trimmedEmail,
                message: normalizedMessage,
                attachments: attachments
            )
            await MainActor.run {
                isSubmitting = false
                didSend = true
                attachments = []
            }
        } catch {
            await MainActor.run {
                isSubmitting = false
                submissionErrorMessage = userFacingErrorMessage(for: error)
            }
        }
    }

    private func isValidEmail(_ rawValue: String) -> Bool {
        let email = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.isEmpty == false else { return false }
        let pattern = #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return NSPredicate(format: "SELF MATCHES %@", pattern).evaluate(with: email)
    }

    private func userFacingErrorMessage(for error: any Error) -> String {
        guard let submissionError = error as? FeedbackComposerSubmissionError else {
            return String(
                localized: "sidebar.help.feedback.genericError",
                defaultValue: "Couldn't send feedback. Please try again.",
                bundle: .module
            )
        }

        switch submissionError {
        case .invalidEndpoint:
            return String(
                localized: "sidebar.help.feedback.endpointError",
                defaultValue: "Feedback is unavailable right now. Email founders@manaflow.com instead.",
                bundle: .module
            )
        case .invalidResponse:
            return String(
                localized: "sidebar.help.feedback.genericError",
                defaultValue: "Couldn't send feedback. Please try again.",
                bundle: .module
            )
        case .attachmentReadFailed:
            return String(
                localized: "sidebar.help.feedback.invalidImageSelection",
                defaultValue: "One of the selected files could not be attached.",
                bundle: .module
            )
        case .attachmentPreparationFailed:
            return String(
                localized: "sidebar.help.feedback.totalImagesTooLarge",
                defaultValue: "These images are too large to send together. Remove a few and try again.",
                bundle: .module
            )
        case .transport(let transportError):
            if transportError.code == .notConnectedToInternet || transportError.code == .networkConnectionLost {
                return String(
                    localized: "sidebar.help.feedback.connectionError",
                    defaultValue: "Couldn't send feedback. Check your connection and try again.",
                    bundle: .module
                )
            }
            return String(
                localized: "sidebar.help.feedback.genericError",
                defaultValue: "Couldn't send feedback. Please try again.",
                bundle: .module
            )
        case .rejected(let statusCode):
            switch statusCode {
            case 400, 413, 415:
                return String(
                    localized: "sidebar.help.feedback.validationError",
                    defaultValue: "Check your message and attachments, then try again.",
                    bundle: .module
                )
            case 429:
                return String(
                    localized: "sidebar.help.feedback.rateLimited",
                    defaultValue: "Too many feedback attempts. Please try again later.",
                    bundle: .module
                )
            case 500...599:
                return String(
                    localized: "sidebar.help.feedback.endpointError",
                    defaultValue: "Feedback is unavailable right now. Email founders@manaflow.com instead.",
                    bundle: .module
                )
            default:
                return String(
                    localized: "sidebar.help.feedback.genericError",
                    defaultValue: "Couldn't send feedback. Please try again.",
                    bundle: .module
                )
            }
        }
    }
}
