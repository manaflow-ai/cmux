import CmuxNextTerminal

/// Leo 2026-10-13: a terminal with no output yet (a new shell's prompt, at most a login line
/// above it) has no preview; its tab's hover card shows its plain state, not a picture of an
/// empty prompt. A finished command, or a screen with more than that, is output.
@MainActor
enum TerminalOutput {
    static func shows(_ session: TerminalSession) -> Bool {
        if session.model.lastCommand != nil { return true }
        // No surface to read (released): what it showed when it had one stands.
        guard let text = session.surfaceView.viewportText() else { return true }
        return text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }.count > 2
    }
}
