import Foundation

enum TextBoxSubmitAvailability {
    static func shouldShowPlaceholder(
        text: String,
        attachmentCount: Int,
        hasMarkedText: Bool
    ) -> Bool {
        text.isEmpty && attachmentCount == 0 && !hasMarkedText
    }

    static func shouldEnableSubmit(
        text: String,
        attachmentCount: Int,
        hasPendingAttachmentUpload: Bool,
        hasMarkedText: Bool
    ) -> Bool {
        !hasPendingAttachmentUpload
            && !hasMarkedText
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachmentCount > 0)
    }

    static func shouldSubmit(
        hasPendingAttachmentUpload: Bool,
        hasMarkedText: Bool
    ) -> Bool {
        !hasPendingAttachmentUpload && !hasMarkedText
    }
}
