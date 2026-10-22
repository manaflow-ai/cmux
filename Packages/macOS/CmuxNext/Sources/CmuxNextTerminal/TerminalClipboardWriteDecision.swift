/// What a terminal clipboard write callback does with the text.
nonisolated enum TerminalClipboardWriteDecision: Sendable, Equatable {
    /// Put the text on the pasteboard now, with no dialog.
    case write
    /// Show the consent dialog first (`clipboard-write = ask`).
    case confirm
}
