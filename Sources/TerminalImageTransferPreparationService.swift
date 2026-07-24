import AppKit
import Foundation

/// Resolves pasteboard providers and materializes terminal paste content outside the main actor.
struct TerminalImageTransferPreparationService: Sendable {
#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    nonisolated func prepare(
        request: TerminalPasteboardReadRequest,
        mode: TerminalImageTransferMode
    ) async -> TerminalImageTransferPreparedContent {
        guard !Task.isCancelled else { return .reject }

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(request.pasteboardName)
        )
        guard pasteboard.changeCount == request.changeCount else {
            return .reject
        }

        let preparedContent = TerminalImageTransferPlanner.prepareSynchronously(
            pasteboard: pasteboard,
            mode: mode
        )
        guard !Task.isCancelled,
              pasteboard.changeCount == request.changeCount else {
            preparedContent.cleanupTransferredTemporaryFiles()
            return .reject
        }
        return preparedContent
    }
}
