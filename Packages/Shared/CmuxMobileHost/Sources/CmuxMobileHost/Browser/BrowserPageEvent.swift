import CmuxBrowserStream

/// What the page owner reports while a phone is attached.
public enum BrowserPageEvent: Hashable, Sendable {
    case page(RbPage)
    case cursor(RbCursorShape)
    case textInput(inputType: String, caret: RbRect?)
    case clipboardWrite([RbClipboardItem])
    /// The Mac page viewport changed (the Mac pane was resized).
    case geometry(BrowserPageGeometry)
    /// The tab closed or its engine went away; last event.
    case closed(reason: String)
}
