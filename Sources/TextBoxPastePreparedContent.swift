enum TextBoxPastePreparedContent: Equatable, Sendable {
    case insertText(String)
    case attachments([TextBoxPreparedAttachment])
    case reject

    /// Releases temporary images that will not be inserted into the composer.
    func cleanupTransferredTemporaryFiles() {
        guard case .attachments(let attachments) = self else { return }
        GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(
            attachments.map(\.fileURL)
        )
    }
}
