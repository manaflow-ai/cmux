/// The terminal cursor shape, as Ghostty's `cursor-style` names it.
public enum TerminalCursorStyle: String, Hashable, Sendable, Codable, CaseIterable {
    case block
    case bar
    case underline
}
