extension TerminalImageTransferPreparedContent {
    /// Releases any temporary image files created while preparing this value.
    func cleanupTransferredTemporaryFiles() {
        guard case .fileURLs(let fileURLs) = self else { return }
        GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
    }
}
