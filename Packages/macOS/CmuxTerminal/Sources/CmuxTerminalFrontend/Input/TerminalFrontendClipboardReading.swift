/// Main-actor clipboard source for terminal paste actions.
@MainActor
public protocol TerminalFrontendClipboardReading: AnyObject {
    /// Whether plain text is available without materializing its payload.
    var hasTerminalText: Bool { get }

    /// Returns the platform clipboard's plain-text value when one is available.
    func readTerminalText() -> String?
}

public extension TerminalFrontendClipboardReading {
    /// Default availability check for injected sources without metadata access.
    var hasTerminalText: Bool {
        guard let text = readTerminalText() else { return false }
        return !text.isEmpty
    }
}
