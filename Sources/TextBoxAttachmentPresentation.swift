enum TextBoxAttachmentPresentation {
    /// Individual cells preserve rich previews for normal prompts. Larger insertions use one
    /// collection cell so TextKit layout cost is independent of the number of selected files.
    static let maximumIndividualCellsPerInsertion = 20

    static func groups(for attachments: [TextBoxAttachment]) -> [TextBoxAttachmentGroup] {
        guard !attachments.isEmpty else { return [] }
        guard attachments.count <= maximumIndividualCellsPerInsertion else {
            return [TextBoxAttachmentGroup(attachments: attachments)]
        }
        return attachments.map { TextBoxAttachmentGroup(attachments: [$0]) }
    }
}
