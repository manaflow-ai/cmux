/// Describes one libghostty input operation after AppKit interprets a key.
public enum TerminalKeyInputAction: Sendable, Equatable {
    /// Sends text committed from an existing preedit without physical-key metadata.
    case sendCommittedText(String)

    /// Sends an AppKit text commit with the native key's physical metadata.
    ///
    /// Keeping this provenance distinct lets the lifecycle tracker preserve
    /// the text as a nonphysical commit when AppKit owns the original press.
    case sendCommittedKey(String)

    /// Sends the physical key with optional committed text and composition state.
    case sendKey(text: String?, composing: Bool)

    /// Whether this operation forwards an encodable physical key.
    public var forwardsPhysicalKey: Bool {
        switch self {
        case .sendCommittedText:
            return false
        case .sendCommittedKey:
            return true
        case .sendKey(_, composing: let composing):
            return !composing
        }
    }

    var isPhysicalKey: Bool {
        switch self {
        case .sendCommittedText:
            return false
        case .sendCommittedKey, .sendKey:
            return true
        }
    }

    var withoutPhysicalOwnership: TerminalKeyInputAction? {
        switch self {
        case .sendCommittedText:
            return self
        case .sendCommittedKey(let text):
            return .sendCommittedText(text)
        case .sendKey:
            return nil
        }
    }
}
