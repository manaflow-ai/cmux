import AppKit

extension TextBoxInputTextView {
    /// Projects binding-visible content while restoring private pending-paste selections.
    @MainActor
    func bindingContentForPreservation() -> (
        text: String,
        attachments: [TextBoxAttachment]
    ) {
        let projectedParts = TextBoxSubmissionFormatter.parts(
            from: attributedContentForPreservation()
        )
        var projectedText = ""
        var projectedAttachments: [TextBoxAttachment] = []
        for part in projectedParts {
            switch part {
            case .text(let text):
                projectedText += text
            case .attachment(let attachment):
                projectedAttachments.append(attachment)
            }
        }
        return (projectedText, projectedAttachments)
    }

    /// Synchronizes an authoritative plain-text binding without exposing or
    /// destroying private pending-paste markers.
    @MainActor
    @discardableResult
    func synchronizeExternalTextIfNeeded(_ externalText: String) -> Bool {
        let projectedContent = bindingContentForPreservation()
        guard shouldSynchronizeExternalTextToTextBox(
            inlineAttachmentCount: projectedContent.attachments.count,
            plainText: projectedContent.text,
            externalText: externalText,
            hasMarkedText: hasMarkedText()
        ) else {
            return false
        }

        invalidatePendingAttachmentUploads()
        string = externalText
        return true
    }
}
