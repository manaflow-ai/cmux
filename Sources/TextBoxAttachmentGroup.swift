import Foundation

struct TextBoxAttachmentGroup: Identifiable {
    let id: UUID
    let attachments: [TextBoxAttachment]

    init(attachments: [TextBoxAttachment]) {
        precondition(!attachments.isEmpty)
        self.attachments = attachments
        self.id = attachments.count == 1 ? attachments[0].id : UUID()
    }

    var primaryAttachment: TextBoxAttachment {
        attachments[0]
    }

    var displayName: String {
        guard attachments.count > 1 else { return primaryAttachment.displayName }
        let format = String(
            localized: "textbox.attachmentGroup.many",
            defaultValue: "%lld files"
        )
        return String.localizedStringWithFormat(format, Int64(attachments.count))
    }

    var inlineThumbnailSource: TextBoxInlineAttachmentThumbnailSource? {
        attachments.count == 1 ? primaryAttachment.inlineThumbnailSource : nil
    }
}
