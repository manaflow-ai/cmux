/// The outcome of one ordered pasteboard mutation.
public struct TerminalPasteboardMutationResult: Sendable {
    /// Why the mutation did or did not publish its requested contents.
    public enum Status: Equatable, Sendable {
        case written
        case conditionNotMet
        case captureLimitExceeded
        case writeFailed
        case queueFull
        case cancelled
    }

    /// The mutation outcome.
    public let status: Status

    /// The contents replaced by a successful mutation that requested capture.
    public let previousContents: [TerminalPasteboardItemSnapshot]?

    /// The contents the mutation attempted to publish.
    public let publishedContents: [TerminalPasteboardItemSnapshot]

    /// Whether the requested contents were published.
    public var didWrite: Bool {
        status == .written
    }

    init(
        status: Status,
        previousContents: [TerminalPasteboardItemSnapshot]? = nil,
        publishedContents: [TerminalPasteboardItemSnapshot]
    ) {
        self.status = status
        self.previousContents = previousContents
        self.publishedContents = publishedContents
    }
}
