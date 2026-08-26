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
    /// One indivisible composed prompt: app-owned preparation keys followed by
    /// bracketed-paste text and its agent-aware submit key. Hook attribution is
    /// carried with the queued transaction but is not recorded until the item
    /// is actually flushed.
    case promptSubmission(
        preparationKeys: [PendingKeyEvent],
        text: Data,
        submitKey: PendingKeyEvent,
        hookRecordingSource: String?,
        hookConfirmedHumanInputSnapshot:
            TerminalPromptInputLedger.HumanInputSnapshot?
    )
    /// Raw key text to replay as one Ghostty key event.
    case keyText(String)

    /// The byte cost this entry contributes to the pending-input budget.
    public var estimatedBytes: Int {
        switch self {
        case .pasteText(let data), .inputText(let data), .processOutput(let data):
            return data.count
        case .key(let event):
            return event.queuedByteCost
        case .promptSubmission(
            let preparationKeys,
            let text,
            let submitKey,
            _,
            _
        ):
            return preparationKeys.reduce(
                text.count + submitKey.queuedByteCost
            ) { byteCount, event in
                byteCount + event.queuedByteCost
            }
        case .keyText(let text):
            return max(text.utf8.count, 1)
        }
    }
}
