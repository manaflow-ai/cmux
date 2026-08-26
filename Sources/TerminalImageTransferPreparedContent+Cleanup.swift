import CmuxTerminal

extension TerminalImageTransferPreparedContent {
    /// Releases temporary image files owned by the supplied pasteboard service.
    func cleanupTransferredTemporaryFiles(
        using pasteboardService: TerminalPasteboardService
    ) {
        guard case .fileURLs(let fileURLs) = self else { return }
        pasteboardService.cleanupTransferredTemporaryImageFiles(fileURLs)
    }
}
