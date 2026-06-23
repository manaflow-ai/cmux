import Foundation

func shouldShowTextBoxPlaceholder(
    text: String,
    attachmentCount: Int,
    hasMarkedText: Bool
) -> Bool {
    text.isEmpty && attachmentCount == 0 && !hasMarkedText
}

func shouldEnableTextBoxSubmit(
    text: String,
    attachmentCount: Int,
    hasPendingAttachmentUpload: Bool,
    hasMarkedText: Bool
) -> Bool {
    !hasPendingAttachmentUpload
        && !hasMarkedText
        && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachmentCount > 0)
}

func shouldSubmitTextBox(
    hasPendingAttachmentUpload: Bool,
    hasMarkedText: Bool
) -> Bool {
    !hasPendingAttachmentUpload && !hasMarkedText
}
