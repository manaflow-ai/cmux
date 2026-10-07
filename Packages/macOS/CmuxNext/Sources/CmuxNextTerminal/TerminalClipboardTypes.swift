/// Which clipboard Ghostty addressed.
nonisolated enum TerminalPasteboardLocation: Sendable {
    case standard
    /// X11-style primary selection; backs `copy-on-select`.
    case selection
}

nonisolated enum TerminalClipboardRequestKind: Sendable {
    case paste
    case osc52Read
    case osc52Write
}

nonisolated struct TerminalClipboardItem: Sendable {
    var mime: String
    var text: String
}
