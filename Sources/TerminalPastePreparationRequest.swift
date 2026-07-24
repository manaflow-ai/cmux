/// One immutable request submitted to the process-wide paste-preparation lane.
struct TerminalPastePreparationRequest: Sendable {
    let pasteboard: TerminalPasteboardReadRequest
    let mode: TerminalImageTransferMode
    let destination: TerminalPastePreparationDestination
}
