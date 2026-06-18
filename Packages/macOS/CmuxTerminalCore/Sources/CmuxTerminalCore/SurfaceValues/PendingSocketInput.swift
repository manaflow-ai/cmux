public import Foundation

/// One unit of socket-delivered input queued for a not-yet-started surface.
public enum PendingSocketInput: Sendable {
    /// Text delivered through the paste path once the surface starts.
    case pasteText(Data)
    /// Text delivered through the committed-text input path.
    case inputText(Data)
    /// Bytes that must be processed as terminal output, not user input.
    case processOutput(Data)
    /// A named-key press to replay.
    case key(PendingKeyEvent)

    /// The byte cost this entry contributes to the pending-input budget.
    public var estimatedBytes: Int {
        switch self {
        case .pasteText(let data), .inputText(let data), .processOutput(let data):
            return data.count
        case .key(let event):
            return event.queuedByteCost
        }
    }
}
