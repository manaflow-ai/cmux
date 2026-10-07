/// Low-rate events of one browser stream (the page side; video frames come
/// on their own stream).
public enum BrowserStreamEvent: Hashable, Sendable {
    case page(RbPage)
    case state(RbSessionState)
    case cursor(RbCursorShape)
    /// The focused field changed; `inputType` `none` means no text field.
    case textInput(inputType: String, caret: RbRect?)
    /// The page copied: put it on the phone's pasteboard.
    case clipboardWrite([RbClipboardItem])
    /// The encode size changed (after `rb.screen`); the next frame is a keyframe.
    case screenApplied(pixelWidth: UInt32, pixelHeight: UInt32)
    /// The newest input sequence number the Mac applied.
    case inputApplied(UInt32)
    /// The datagram lane attached or detached.
    case datagramLane(active: Bool)
    /// The stream ended; last event.
    case closed(reason: String)
}
