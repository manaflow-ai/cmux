/// One typed input for a terminal, as the daemon takes it: text written as typed (`send`), or a key by its
/// `send-key` name, which the daemon's Ghostty key encoder encodes with the program's own keyboard modes.
public nonisolated enum TerminalTypedInput: Sendable, Equatable {
    case text(String)
    case key(String)
}
