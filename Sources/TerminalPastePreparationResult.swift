import CmuxTerminal

/// A prepared value returned by the shared terminal/composer paste pipeline.
enum TerminalPastePreparationResult: Codable, Sendable {
    case terminal(TerminalImageTransferPreparedContent)
    case composer(TextBoxPastePreparedContent)
    case pasteboardSnapshot(TerminalPasteboardContentsSnapshot?)

    func cleanupTransferredTemporaryFiles(
        using pasteboardService: TerminalPasteboardService
    ) {
        switch self {
        case .terminal(let content):
            content.cleanupTransferredTemporaryFiles(
                using: pasteboardService
            )
        case .composer(let content):
            content.cleanupTransferredTemporaryFiles(
                using: pasteboardService
            )
        case .pasteboardSnapshot:
            break
        }
    }
}
