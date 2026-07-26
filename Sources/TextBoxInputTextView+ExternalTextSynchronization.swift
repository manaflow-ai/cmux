import AppKit

extension TextBoxInputTextView {
    /// Synchronizes an authoritative plain-text binding without exposing or
    /// destroying private pending-paste markers.
    @MainActor
    @discardableResult
    func synchronizeExternalTextIfNeeded(_ externalText: String) -> Bool {
        let projectedParts = TextBoxSubmissionFormatter.parts(
            from: attributedContentForPreservation()
        )
        var projectedText = ""
        var projectedAttachmentCount = 0
        for part in projectedParts {
            switch part {
            case .text(let text):
                projectedText += text
            case .attachment:
                projectedAttachmentCount += 1
            }
        }
        guard shouldSynchronizeExternalTextToTextBox(
            inlineAttachmentCount: projectedAttachmentCount,
            plainText: projectedText,
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
