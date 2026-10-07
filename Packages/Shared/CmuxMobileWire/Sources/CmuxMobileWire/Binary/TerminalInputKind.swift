/// Kind byte of a terminal input record.
public enum TerminalInputKind: UInt8, Hashable, Sendable {
    /// Ghostty-encoded keys, mouse and committed IME text.
    case bytes = 0
    /// UTF-8 text; the host applies bracketed paste by its own mode.
    case paste = 1
}
