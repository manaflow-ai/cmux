#if os(iOS)
import CmuxMobileDiagnostics
import CmuxMobileFeedback
import CmuxMobileSupport
import PhotosUI
import SwiftUI

struct MobileFeedbackComposerSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var message = ""
    @State private var diagnosticsReport: MobileDiagnosticsReport?
    @State private var isPreparingDiagnostics = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var photoAttachments: [MobileFeedbackPhotoAttachment] = []
    @State private var isPreparingPhotos = false
    @State private var isSubmitting = false
    @State private var submissionErrorMessage: String?
    @State private var didSend = false
    @State private var didApplyInitialEmail = false

    private let initialEmail: String?
    private let buildDiagnosticsReport: @MainActor () async -> MobileDiagnosticsReport
    private let client: any MobileFeedbackSubmitting

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        isValidEmail(email) &&
            trimmedMessage.isEmpty == false &&
            message.count <= MobileFeedbackSettings.maxMessageLength &&
            diagnosticsReport != nil &&
            isSubmitting == false &&
            isPreparingPhotos == false &&
            didSend == false
    }

    init(
        initialEmail: String? = nil,
        initialDiagnosticsReport: MobileDiagnosticsReport?,
        buildDiagnosticsReport: @escaping @MainActor () async -> MobileDiagnosticsReport,
        client: any MobileFeedbackSubmitting
    ) {
        self.initialEmail = Self.normalizedInitialEmail(initialEmail)
        self.buildDiagnosticsReport = buildDiagnosticsReport
        self.client = client
        _diagnosticsReport = State(initialValue: initialDiagnosticsReport)
    }

    var body: some View {
        NavigationStack {
            Group {
                if didSend {
                    successView
                } else {
                    formView
                }
            }
            .navigationTitle(L10n.string("mobile.feedback.title", defaultValue: "Send Feedback"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.feedback.cancel", defaultValue: "Cancel")) {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }

                ToolbarItem(placement: .confirmationAction) {
                    if didSend {
                        Button(L10n.string("mobile.feedback.done", defaultValue: "Done")) {
                            dismiss()
                        }
                    } else {
                        Button {
                            Task { await submitFeedback() }
                        } label: {
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Text(L10n.string("mobile.feedback.send", defaultValue: "Send"))
                            }
                        }
                        .disabled(canSubmit == false)
                        .accessibilityIdentifier("MobileFeedbackSendButton")
                    }
                }
            }
        }
        .task {
            await applyInitialEmailIfNeeded()
            await ensureDiagnosticsReport()
        }
        .onChange(of: selectedPhotoItems) { _, newItems in
            guard newItems.isEmpty == false else { return }
            Task { await loadSelectedPhotos(newItems) }
        }
        .accessibilityIdentifier("MobileFeedbackComposerSheet")
    }

    private var successView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.green)
            Text(L10n.string("mobile.feedback.successTitle", defaultValue: "Thanks for the feedback."))
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(
                L10n.string(
                    "mobile.feedback.successBody",
                    defaultValue: "You can also reach us at founders@manaflow.com."
                )
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var formView: some View {
        Form {
            Section {
                TextField(
                    L10n.string("mobile.feedback.emailPlaceholder", defaultValue: "you@example.com"),
                    text: $email
                )
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(L10n.string("mobile.feedback.email", defaultValue: "Your Email"))
                .accessibilityIdentifier("MobileFeedbackEmailField")
            } header: {
                Text(L10n.string("mobile.feedback.email", defaultValue: "Your Email"))
            }

            Section {
                messageEditor
            } header: {
                Text(L10n.string("mobile.feedback.message", defaultValue: "Message"))
            } footer: {
                Text("\(message.count)/\(MobileFeedbackSettings.maxMessageLength)")
                    .foregroundStyle(message.count > MobileFeedbackSettings.maxMessageLength ? .red : .secondary)
            }

            Section {
                HStack(spacing: 12) {
                    Label(L10n.string("mobile.feedback.diagnostics", defaultValue: "Diagnostics"), systemImage: "doc.text")
                    Spacer(minLength: 0)
                    if isPreparingDiagnostics {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.string("mobile.feedback.diagnosticsPreparing", defaultValue: "Preparing…"))
                            .foregroundStyle(.secondary)
                    } else if diagnosticsReport != nil {
                        Text(L10n.string("mobile.feedback.diagnosticsReady", defaultValue: "Ready"))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.string("mobile.feedback.diagnosticsNotReady", defaultValue: "Not Ready"))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: max(1, MobileFeedbackSettings.maxPhotoAttachmentCount - photoAttachments.count),
                    matching: .images
                ) {
                    Label(L10n.string("mobile.feedback.attachPhotos", defaultValue: "Attach Photos"), systemImage: "paperclip")
                }
                .disabled(photoAttachments.count >= MobileFeedbackSettings.maxPhotoAttachmentCount || isPreparingPhotos)
                .accessibilityIdentifier("MobileFeedbackAttachPhotosButton")

                if isPreparingPhotos {
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.string("mobile.feedback.photosPreparing", defaultValue: "Preparing Photos…"))
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(photoAttachments) { attachment in
                    HStack(spacing: 10) {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.fileName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(attachment.displaySize)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button {
                            removePhotoAttachment(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(L10n.string("mobile.feedback.removePhoto", defaultValue: "Remove Photo"))
                    }
                }
            } header: {
                Text(L10n.string("mobile.feedback.photos", defaultValue: "Photos"))
            } footer: {
                Text(L10n.string("mobile.feedback.photosHint", defaultValue: "Optional, up to 10 photos."))
            }

            if let submissionErrorMessage, submissionErrorMessage.isEmpty == false {
                Section {
                    Text(submissionErrorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var messageEditor: some View {
        ZStack(alignment: .topLeading) {
            if message.isEmpty {
                Text(
                    L10n.string(
                        "mobile.feedback.messagePlaceholder",
                        defaultValue: "Share feedback, feature requests, or issues."
                    )
                )
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
            }

            TextEditor(text: $message)
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .accessibilityLabel(L10n.string("mobile.feedback.message", defaultValue: "Message"))
                .accessibilityIdentifier("MobileFeedbackMessageEditor")
        }
    }

    @MainActor
    private func applyInitialEmailIfNeeded() {
        guard didApplyInitialEmail == false else { return }
        didApplyInitialEmail = true
        guard let initialEmail else { return }
        let currentEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentEmail != initialEmail else { return }
        email = initialEmail
    }

    @MainActor
    @discardableResult
    private func ensureDiagnosticsReport() async -> MobileDiagnosticsReport? {
        if let diagnosticsReport {
            return diagnosticsReport
        }
        guard isPreparingDiagnostics == false else { return nil }

        isPreparingDiagnostics = true
        defer { isPreparingDiagnostics = false }
        let report = await buildDiagnosticsReport()
        diagnosticsReport = report
        return report
    }

    @MainActor
    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) async {
        guard items.isEmpty == false else { return }
        guard isPreparingPhotos == false else { return }

        isPreparingPhotos = true
        defer {
            isPreparingPhotos = false
            selectedPhotoItems = []
        }

        var firstIssue: String?
        let startingPhotoBytes = photoAttachments.reduce(0) { $0 + $1.data.count }
        let startingCount = photoAttachments.count
        let finalCount = min(
            MobileFeedbackSettings.maxPhotoAttachmentCount,
            startingCount + items.count
        )
        let requestedNewCount = max(0, finalCount - startingCount)
        guard requestedNewCount > 0 else {
            submissionErrorMessage = L10n.string(
                "mobile.feedback.tooManyPhotos",
                defaultValue: "You can attach up to 10 photos."
            )
            return
        }

        let remainingPhotoBytes = MobileFeedbackSettings.targetTotalPhotoUploadBytes - startingPhotoBytes
        guard remainingPhotoBytes > 0 else {
            submissionErrorMessage = L10n.string(
                "mobile.feedback.totalPhotosTooLarge",
                defaultValue: "These photos are too large to send together. Remove a few and try again."
            )
            return
        }

        let perAttachmentBudget = max(1, remainingPhotoBytes / requestedNewCount)
        var preparedAttachments: [MobileFeedbackPhotoAttachment] = []

        for item in items {
            guard preparedAttachments.count < requestedNewCount else {
                firstIssue = L10n.string(
                    "mobile.feedback.tooManyPhotos",
                    defaultValue: "You can attach up to 10 photos."
                )
                break
            }

            do {
                let attachment = try await MobileFeedbackPhotoAttachment.make(
                    from: item,
                    index: startingCount + preparedAttachments.count + 1,
                    maximumByteCount: perAttachmentBudget
                )
                preparedAttachments.append(attachment)
            } catch MobileFeedbackSubmissionError.photoPreparationFailed {
                firstIssue = L10n.string(
                    "mobile.feedback.totalPhotosTooLarge",
                    defaultValue: "These photos are too large to send together. Remove a few and try again."
                )
            } catch {
                firstIssue = L10n.string(
                    "mobile.feedback.invalidPhotoSelection",
                    defaultValue: "One of the selected photos could not be attached."
                )
            }
        }

        if preparedAttachments.isEmpty == false {
            let openSlots = max(0, MobileFeedbackSettings.maxPhotoAttachmentCount - photoAttachments.count)
            if openSlots > 0 {
                photoAttachments.append(contentsOf: preparedAttachments.prefix(openSlots))
            }
            if preparedAttachments.count > openSlots {
                firstIssue = L10n.string(
                    "mobile.feedback.tooManyPhotos",
                    defaultValue: "You can attach up to 10 photos."
                )
            }
        }
        submissionErrorMessage = firstIssue
    }

    @MainActor
    private func removePhotoAttachment(_ attachment: MobileFeedbackPhotoAttachment) {
        photoAttachments.removeAll { $0.id == attachment.id }
        submissionErrorMessage = nil
    }

    @MainActor
    private func submitFeedback() async {
        guard isSubmitting == false else { return }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = trimmedMessage

        guard isValidEmail(trimmedEmail) else {
            submissionErrorMessage = L10n.string(
                "mobile.feedback.invalidEmail",
                defaultValue: "Enter a valid email address."
            )
            return
        }

        guard normalizedMessage.isEmpty == false else {
            submissionErrorMessage = L10n.string(
                "mobile.feedback.emptyMessage",
                defaultValue: "Enter a message before sending."
            )
            return
        }

        guard message.count <= MobileFeedbackSettings.maxMessageLength else {
            submissionErrorMessage = L10n.string(
                "mobile.feedback.messageTooLong",
                defaultValue: "Your message is too long."
            )
            return
        }

        submissionErrorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        let report = await refreshDiagnosticsReport()

        do {
            let metadata = MobileFeedbackAppMetadata.current()
            try await client.submit(
                email: trimmedEmail,
                message: normalizedMessage,
                diagnosticsReport: report,
                photoAttachments: photoAttachments,
                metadata: metadata
            )
            didSend = true
            photoAttachments = []
        } catch {
            submissionErrorMessage = userFacingErrorMessage(for: error)
        }
    }

    @MainActor
    private func refreshDiagnosticsReport() async -> MobileDiagnosticsReport {
        isPreparingDiagnostics = true
        defer { isPreparingDiagnostics = false }
        let report = await buildDiagnosticsReport()
        diagnosticsReport = report
        return report
    }

    private func isValidEmail(_ rawValue: String) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else { return false }
        let pattern = #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return NSPredicate(format: "SELF MATCHES %@", pattern).evaluate(with: value)
    }

    static func normalizedInitialEmail(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false else {
            return nil
        }
        return value
    }

    private func userFacingErrorMessage(for error: Error) -> String {
        guard let submissionError = error as? MobileFeedbackSubmissionError else {
            return L10n.string(
                "mobile.feedback.genericError",
                defaultValue: "Couldn't send feedback. Please try again."
            )
        }

        switch submissionError {
        case .invalidEndpoint:
            return L10n.string(
                "mobile.feedback.endpointError",
                defaultValue: "Feedback is unavailable right now. Email founders@manaflow.com instead."
            )
        case .invalidResponse:
            return L10n.string(
                "mobile.feedback.genericError",
                defaultValue: "Couldn't send feedback. Please try again."
            )
        case .photoReadFailed:
            return L10n.string(
                "mobile.feedback.invalidPhotoSelection",
                defaultValue: "One of the selected photos could not be attached."
            )
        case .photoPreparationFailed:
            return L10n.string(
                "mobile.feedback.totalPhotosTooLarge",
                defaultValue: "These photos are too large to send together. Remove a few and try again."
            )
        case .diagnosticsPreparationFailed:
            return L10n.string(
                "mobile.feedback.diagnosticsUnavailable",
                defaultValue: "Diagnostics are still being prepared. Try again in a moment."
            )
        case .transport(let transportError):
            if transportError.code == .notConnectedToInternet || transportError.code == .networkConnectionLost {
                return L10n.string(
                    "mobile.feedback.connectionError",
                    defaultValue: "Couldn't send feedback. Check your connection and try again."
                )
            }
            return L10n.string(
                "mobile.feedback.genericError",
                defaultValue: "Couldn't send feedback. Please try again."
            )
        case .rejected(let statusCode):
            switch statusCode {
            case 400, 413, 415:
                return L10n.string(
                    "mobile.feedback.validationError",
                    defaultValue: "Check your message and attachments, then try again."
                )
            case 429:
                return L10n.string(
                    "mobile.feedback.rateLimited",
                    defaultValue: "Too many feedback attempts. Please try again later."
                )
            case 500...599:
                return L10n.string(
                    "mobile.feedback.endpointError",
                    defaultValue: "Feedback is unavailable right now. Email founders@manaflow.com instead."
                )
            default:
                return L10n.string(
                    "mobile.feedback.genericError",
                    defaultValue: "Couldn't send feedback. Please try again."
                )
            }
        }
    }
}
#endif
