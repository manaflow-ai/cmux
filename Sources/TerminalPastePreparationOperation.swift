import AppKit
import CmuxTerminal

/// Performs one complete pasteboard read with process-local file ownership.
struct TerminalPastePreparationOperation: Sendable {
    private let pasteboardService: TerminalPasteboardService

    init(pasteboardService: TerminalPasteboardService) {
        self.pasteboardService = pasteboardService
    }

    func prepare(
        request: TerminalPastePreparationRequest
    ) -> TerminalPastePreparationResult {
        let readRequest = request.pasteboard
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(readRequest.pasteboardName)
        )
        guard pasteboard.changeCount == readRequest.changeCount else {
            return rejectedResult(for: request.destination)
        }

        let preparedContent = TerminalImageTransferPlanner.prepareSynchronously(
            pasteboard: pasteboard,
            mode: request.mode,
            pasteboardService: pasteboardService
        )
        guard pasteboard.changeCount == readRequest.changeCount else {
            preparedContent.cleanupTransferredTemporaryFiles(
                using: pasteboardService
            )
            return rejectedResult(for: request.destination)
        }

        switch request.destination {
        case .terminal:
            return .terminal(preparedContent)
        case .composer:
            return .composer(
                TextBoxPastePreparationService().prepare(
                    preparedContent: preparedContent
                )
            )
        }
    }

    private func rejectedResult(
        for destination: TerminalPastePreparationDestination
    ) -> TerminalPastePreparationResult {
        switch destination {
        case .terminal:
            return .terminal(.reject)
        case .composer:
            return .composer(.reject)
        }
    }
}
