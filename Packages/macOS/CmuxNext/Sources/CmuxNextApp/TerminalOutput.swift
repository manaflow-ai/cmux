import CmuxNextTerminal

/// Leo 2026-10-13: a terminal with no output yet (a new shell's prompt, under at most its
/// "Last login" line) has no preview; its tab's hover card shows its plain state, not a picture
/// of an empty prompt. A finished command, or any other line (a running command's first output
/// counts: only a finished one is reported), is output.
@MainActor
enum TerminalOutput {
    static func shows(_ session: TerminalSession) -> Bool {
        if session.model.lastCommand != nil { return true }
        // No surface to read (released): what it showed when it had one stands.
        guard let text = session.surfaceView.viewportText() else { return true }
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        return lines.drop { $0.hasPrefix("Last login:") }.count > 1
    }
}
