import CmuxTerminal

/// One immutable request submitted to the process-wide paste-preparation lane.
struct TerminalPastePreparationRequest: Codable, Sendable {
    let pasteboard: TerminalPasteboardReadRequest
    let mode: TerminalImageTransferMode?
    let destination: TerminalPastePreparationDestination?
    let snapshotMaximumByteCount: Int?

    init(
        pasteboard: TerminalPasteboardReadRequest,
        mode: TerminalImageTransferMode,
        destination: TerminalPastePreparationDestination
    ) {
        self.pasteboard = pasteboard
        self.mode = mode
        self.destination = destination
        snapshotMaximumByteCount = nil
    }

    init(snapshot request: TerminalPasteboardContentsCaptureRequest) {
        pasteboard = TerminalPasteboardReadRequest(
            pasteboardName: request.pasteboardName,
            changeCount: request.changeCount
        )
        mode = nil
        destination = nil
        snapshotMaximumByteCount = request.maximumByteCount
    }
}
