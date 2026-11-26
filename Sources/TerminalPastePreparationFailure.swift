/// Why an accepted paste-preparation request produced no content.
enum TerminalPastePreparationFailure: Error, Equatable, Sendable {
    case cancelled
    case deadlineExceeded
    case queueFull
    case workerFailed
}
