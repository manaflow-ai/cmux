import AppKit

extension TextBoxInputContainer {
    func handlePaste(
        _ pasteboard: NSPasteboard,
        into textView: TextBoxInputTextView
    ) -> Bool {
        guard let preparationService = surface.hostedView
            .surfaceView.imageTransferPreparation else {
            return false
        }
        return textView.beginPreparingPaste(
            from: pasteboard,
            using: preparationService
        ) {
            textView,
            placeholderID,
            validationToken,
            preparedContent in
            completePreparedPaste(
                preparedContent,
                in: textView,
                placeholderID: placeholderID,
                validationToken: validationToken,
                preparationService: preparationService
            )
        }
    }

    private func completePreparedPaste(
        _ preparedContent: TextBoxPastePreparedContent,
        in textView: TextBoxInputTextView,
        placeholderID: UUID,
        validationToken: UInt64,
        preparationService: TerminalImageTransferPreparationService
    ) {
        guard ownsTextView(textView),
              textView.canAcceptPendingAttachmentUpload(
                validationToken: validationToken
              ) else {
            _ = textView.rollbackPendingPasteReservation(
                id: placeholderID,
                notifyingTextChange: false
            )
            preparationService.cleanupTransferredTemporaryFiles(
                preparedContent
            )
            return
        }

        switch preparedContent {
        case .insertText(let insertedText):
            guard textView.replacePendingAttachmentUploadPlaceholder(
                id: placeholderID,
                withText: insertedText
            ) else {
                preparationService.cleanupTransferredTemporaryFiles(
                    preparedContent
                )
                return
            }
            publishComposerContent(from: textView)
        case .attachments(let preparedAttachments):
            attachPreparedPasteAttachments(
                preparedAttachments,
                to: textView,
                placeholderID: placeholderID,
                validationToken: validationToken,
                preparationService: preparationService
            )
        case .reject:
            if textView.removePendingAttachmentUploadPlaceholder(
                id: placeholderID
            ) {
                publishComposerContent(from: textView)
            }
        }
    }

    private func attachPreparedPasteAttachments(
        _ preparedAttachments: [TextBoxPreparedAttachment],
        to textView: TextBoxInputTextView,
        placeholderID: UUID,
        validationToken: UInt64,
        preparationService: TerminalImageTransferPreparationService
    ) {
        guard !preparedAttachments.isEmpty else {
            _ = textView.removePendingAttachmentUploadPlaceholder(
                id: placeholderID
            )
            publishComposerContent(from: textView)
            return
        }

        let fileURLs = preparedAttachments.map(\.fileURL)
        let plan = TerminalImageTransferPlanner.plan(
            fileURLs: fileURLs,
            target: surface.resolvedImageTransferTarget(),
            mode: .paste
        )

        switch plan {
        case .insertText, .insertTextSegments:
            let newAttachments = preparedAttachments.map {
                TextBoxAttachment(
                    preparedAttachment: $0,
                    submissionText: TextBoxAttachment.submissionText(
                        forLocalFileURL: $0.fileURL
                    ),
                    cleanupLocalURLWhenDisposed: TextBoxAttachment
                        .shouldCleanupLocalURLWhenDisposed($0.fileURL)
                )
            }
            guard textView.replacePendingAttachmentUploadPlaceholder(
                id: placeholderID,
                with: newAttachments
            ) else {
                preparedContentCleanup(
                    preparedAttachments,
                    using: preparationService
                )
                return
            }
            publishComposerContent(from: textView)
        case .uploadFiles(let uploadURLs, let remoteTarget):
            uploadFileAttachments(
                uploadURLs,
                remoteTarget: remoteTarget,
                focusing: textView,
                replacingPlaceholderID: placeholderID,
                validationToken: validationToken,
                preparedAttachments: preparedAttachments,
                preparationService: preparationService
            )
        case .reject:
            _ = textView.removePendingAttachmentUploadPlaceholder(
                id: placeholderID
            )
            preparedContentCleanup(
                preparedAttachments,
                using: preparationService
            )
            publishComposerContent(from: textView)
        }
    }

    private func preparedContentCleanup(
        _ preparedAttachments: [TextBoxPreparedAttachment],
        using preparationService: TerminalImageTransferPreparationService
    ) {
        preparationService.cleanupTransferredTemporaryFiles(
            TextBoxPastePreparedContent.attachments(preparedAttachments)
        )
    }

    func cleanupPreparedPasteFileURLs(
        _ fileURLs: [URL],
        using preparationService: TerminalImageTransferPreparationService?
    ) {
        if let preparationService {
            preparationService.cleanupTransferredTemporaryFiles(
                .fileURLs(fileURLs)
            )
        } else {
            // Legacy synchronous insertion materializes through this process's
            // composition-root pasteboard service rather than a worker owner.
            GhosttyApp.terminalPasteboard
                .cleanupTransferredTemporaryImageFiles(fileURLs)
        }
    }

    private func publishComposerContent(from textView: TextBoxInputTextView) {
        let content = textView.bindingContentForPreservation()
        attachments = content.attachments
        text = content.text
    }
}
