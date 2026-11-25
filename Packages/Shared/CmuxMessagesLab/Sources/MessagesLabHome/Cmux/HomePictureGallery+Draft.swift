import Foundation

/// cmux: the message box's pictures as the large picture viewer's gallery (issue 51939: a picture pasted in the box
/// opened nothing when clicked). A click on one opens it with the box's other pictures around it, in the box's
/// order; files that are not pictures are left out. Values only.
extension HomePictureGallery {
    /// The gallery of `draft`'s pictures showing `opening`; nil when `opening` is not one of them. `file` is a draft
    /// picture's file under its own name (``ChatIntents/draftAttachmentFile(_:)``); a picture with no file yet loads
    /// its thumbnail.
    init?(draft: [Attachment], opening: ID, file: (ID) -> URL?) {
        let pictures = draft.filter { ComposeAttachmentStrip.isImage($0) }
        guard let at = pictures.firstIndex(where: { $0.id == opening }) else { return nil }
        let items = pictures.enumerated().map { i, a in
            let thumbnail = a.asset.flatMap(URL.init(string:))
            return Item(source: HomeMapping.tableAttachmentScheme + a.id,
                        url: file(a.id) ?? thumbnail ?? URL(fileURLWithPath: a.fileName),
                        title: a.fileName.isEmpty ? CmuxStrings.pictureUntitled : a.fileName,
                        row: 0, column: i, thumbnail: thumbnail)
        }
        self.init(items: items, index: at)
    }
}
