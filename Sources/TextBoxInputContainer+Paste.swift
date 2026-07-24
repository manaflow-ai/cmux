import AppKit

extension TextBoxInputContainer {
    func handlePaste(
        _ pasteboard: NSPasteboard,
        into textView: TextBoxInputTextView
    ) -> Bool {
        textView.beginPreparingPaste(from: pasteboard) {
            textView,
            placeholderID,
            validationToken,
            preparedContent in
            completePreparedPaste(
                preparedContent,
                in: textView,
                placeholderID: placeholderID,
                validationToken: validationToken
            )
        }
    }

    private func completePreparedPaste(
        _ preparedContent: TextBoxPastePreparedContent,
        in textView: TextBoxInputTextView,
        placeholderID: UUID,
        validationToken: UInt64
    ) {
        guard ownsTextView(textView),
              textView.canAcceptPendingAttachmentUpload(
                validationToken: validationToken
              ) else {
            preparedContent.cleanupTransferredTemporaryFiles()
            return
        }

        switch preparedContent {
        case .insertText(let insertedText):
            guard textView.replacePendingAttachmentUploadPlaceholder(
                id: placeholderID,
                withText: insertedText
            ) else {
                return
            }
            publishComposerContent(from: textView)
        case .attachments(let preparedAttachments):
            attachPreparedPasteAttachments(
                preparedAttachments,
                to: textView,
                placeholderID: placeholderID,
                validationToken: validationToken
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
        validationToken: UInt64
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
                preparedContentCleanup(preparedAttachments)
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
                preparedAttachments: preparedAttachments
            )
        case .reject:
            _ = textView.removePendingAttachmentUploadPlaceholder(
                id: placeholderID
            )
            preparedContentCleanup(preparedAttachments)
            publishComposerContent(from: textView)
        }
    }

    private func preparedContentCleanup(
        _ preparedAttachments: [TextBoxPreparedAttachment]
    ) {
        GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(
            preparedAttachments.map(\.fileURL)
        )
    }

    private func publishComposerContent(from textView: TextBoxInputTextView) {
        attachments = textView.inlineAttachments()
        text = textView.plainText()
    }
}
