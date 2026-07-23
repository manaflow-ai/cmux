/// Describes one libghostty input operation after AppKit interprets a key.
public enum TerminalKeyInputAction: Sendable, Equatable {
    /// Sends text committed from an existing preedit without physical-key metadata.
    case sendCommittedText(String)

    /// Sends the physical key with optional committed text and composition state.
    case sendKey(text: String?, composing: Bool)
}
