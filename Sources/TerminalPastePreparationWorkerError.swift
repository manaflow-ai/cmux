import Foundation

/// A failure to launch, validate, or decode an isolated paste worker.
enum TerminalPastePreparationWorkerError: Error {
    case invalidWorkerResponse
    case textPayloadTooLarge
    case workerExited(Int32)
}
