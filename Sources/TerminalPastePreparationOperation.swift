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
        if let maximumByteCount = request.snapshotMaximumByteCount {
            guard pasteboard.changeCount == readRequest.changeCount,
                  let contents = TerminalPasteboardItemSnapshot
                    .captureContents(
                        of: pasteboard,
                        maximumByteCount: maximumByteCount
                    ),
                  pasteboard.changeCount == readRequest.changeCount else {
                return .pasteboardSnapshot(nil)
            }
            return .pasteboardSnapshot(
                TerminalPasteboardContentsSnapshot(
                    changeCount: readRequest.changeCount,
                    contents: contents
                )
            )
        }

        guard let mode = request.mode,
              let destination = request.destination else {
            return .pasteboardSnapshot(nil)
        }
        guard pasteboard.changeCount == readRequest.changeCount else {
            return rejectedResult(for: destination)
        }

        let preparedContent = TerminalImageTransferPlanner.prepareSynchronously(
            pasteboard: pasteboard,
            mode: mode,
            pasteboardService: pasteboardService
        )
        guard pasteboard.changeCount == readRequest.changeCount else {
            preparedContent.cleanupTransferredTemporaryFiles(
                using: pasteboardService
            )
            return rejectedResult(for: destination)
        }

        switch destination {
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
