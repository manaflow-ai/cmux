import CmuxTerminal

enum TextBoxPastePreparedContent: Codable, Equatable, Sendable {
    case insertText(String)
    case attachments([TextBoxPreparedAttachment])
    case reject

    /// Releases temporary images that will not be inserted into the composer.
    func cleanupTransferredTemporaryFiles(
        using pasteboardService: TerminalPasteboardService
    ) {
        guard case .attachments(let attachments) = self else { return }
        pasteboardService.cleanupTransferredTemporaryImageFiles(
            attachments.map(\.fileURL)
        )
    }
}
