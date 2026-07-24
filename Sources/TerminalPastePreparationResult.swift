/// A prepared value returned by the shared terminal/composer paste pipeline.
enum TerminalPastePreparationResult: Sendable {
    case terminal(TerminalImageTransferPreparedContent)
    case composer(TextBoxPastePreparedContent)

    func cleanupTransferredTemporaryFiles() {
        switch self {
        case .terminal(let content):
            content.cleanupTransferredTemporaryFiles()
        case .composer(let content):
            content.cleanupTransferredTemporaryFiles()
        }
    }
}
