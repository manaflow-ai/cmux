import Foundation

/// Segments a shell PTY stream into ``TerminalCommandBlock`` values using
/// OSC 133 semantic-prompt marks.
///
/// OSC 133 (FinalTerm shell integration) brackets each command:
/// `ESC]133;A` prompt start, `ESC]133;B` command start (text between B and C
/// is the typed command), `ESC]133;C` output start, `ESC]133;D;<exit>`
/// command end with exit code. The string terminator is BEL (`0x07`) or
/// `ESC \`. Other ANSI/OSC sequences are stripped; carriage-return progress
/// redraws are folded to their final per-line state; entering the alt-screen
/// (`ESC[?1049h`) flags the block interactive so the UI shows a card instead
/// of rendering a full-screen TUI as output.
///
/// Pure and incremental: ``consume(_:)`` may be fed arbitrary chunk
/// boundaries, including ones that split an escape sequence (the tail is
/// carried over). Read ``blocks`` after feeding.
public struct OSC133CommandParser {
    /// The command blocks parsed so far, oldest first.
    public private(set) var blocks: [TerminalCommandBlock] = []

    private enum Phase { case idle, prompt, command, output }
    private var phase: Phase = .idle
    private var commandBuffer = ""
    /// Completed output lines, already carriage-return folded, with their
    /// trailing newlines. Only the still-open line can change when more bytes
    /// arrive, so committed lines are never re-folded — this keeps `consume`
    /// O(chunk) instead of re-folding the whole growing buffer each chunk
    /// (which was O(total) per chunk = quadratic over a long command).
    private var foldedOutput = ""
    /// The current, not-yet-terminated output line (unfolded, may contain
    /// standalone `\r` progress redraws).
    private var openLine = ""
    private var pending = ""
    private var nextID = 0
    private var openIndex: Int?

    /// Bounds the bytes a single (possibly unterminated or hostile) escape
    /// sequence may buffer; past this the sequence is abandoned and scanning
    /// resyncs, so a malformed `ESC]…` with no terminator can't grow
    /// `pending` without bound or wedge the parser. 133 marks are tiny; this
    /// only ever trips on junk or huge ignored sequences (e.g. OSC 52).
    private static let maxEscapeLength = 8192

    /// Creates an empty parser.
    public init() {}

    /// Feeds a chunk of raw terminal output through the state machine.
    ///
    /// - Parameter text: A slice of the PTY stream, any length.
    public mutating func consume(_ text: String) {
        let stream = pending + text
        pending = ""
        var index = stream.startIndex
        while index < stream.endIndex {
            let char = stream[index]
            guard char == "\u{1b}" else {
                appendText(char)
                index = stream.index(after: index)
                continue
            }
            switch parseEscape(stream, at: index) {
            case .parsed(let next, let action):
                apply(action)
                index = next
            case .incomplete:
                // Hold the partial escape until the next chunk completes it,
                // but flush any output collected before it so a split escape
                // mid-stream doesn't stall the live view.
                flushOpenOutput()
                pending = String(stream[index...])
                return
            }
        }
        // Publish the open block's output once per chunk.
        flushOpenOutput()
    }

    /// Publishes the running block's output: the already-folded completed
    /// lines plus the open line folded on its own (O(open line), not O(total)).
    private mutating func flushOpenOutput() {
        guard phase == .output, let openIndex else { return }
        blocks[openIndex].output = foldedOutput + Self.foldLine(openLine)
    }

    // MARK: - Escape parsing

    private enum EscapeResult {
        case parsed(String.Index, EscapeAction)
        case incomplete
    }

    private enum EscapeAction {
        case promptStart
        case commandStart
        case outputStart
        case commandEnd(exitCode: Int?)
        case enterAltScreen
        case leaveAltScreen
        case ignore
    }

    /// Parses one escape sequence beginning at `start` (the ESC). Returns the
    /// index just past the sequence and its action, or `.incomplete` if the
    /// terminator has not arrived yet.
    private func parseEscape(_ s: String, at start: String.Index) -> EscapeResult {
        let afterEsc = s.index(after: start)
        guard afterEsc < s.endIndex else { return .incomplete }
        switch s[afterEsc] {
        case "]":
            return parseOSC(s, bodyStart: s.index(after: afterEsc))
        case "[":
            return parseCSI(s, paramsStart: s.index(after: afterEsc))
        default:
            // Two-byte escape (e.g. ESC\, ESC(B); consume and ignore.
            return .parsed(s.index(after: afterEsc), .ignore)
        }
    }

    /// Parses an OSC sequence body (after `ESC]`) up to BEL or `ESC\`.
    private func parseOSC(_ s: String, bodyStart: String.Index) -> EscapeResult {
        var index = bodyStart
        var body = ""
        while index < s.endIndex {
            // Abandon a runaway/unterminated OSC so it can't grow `pending`
            // without bound; resync as text from here.
            if body.count >= Self.maxEscapeLength {
                return .parsed(index, .ignore)
            }
            let char = s[index]
            if char == "\u{07}" { // BEL terminator
                return .parsed(s.index(after: index), oscAction(body))
            }
            if char == "\u{1b}" { // possible ESC\ terminator
                let next = s.index(after: index)
                guard next < s.endIndex else { return .incomplete }
                if s[next] == "\\" {
                    return .parsed(s.index(after: next), oscAction(body))
                }
                // A stray ESC inside an OSC body: treat the body as ended.
                return .parsed(index, oscAction(body))
            }
            body.append(char)
            index = s.index(after: index)
        }
        return .incomplete
    }

    /// Maps an OSC body to an action. Only `133;...` is meaningful.
    private func oscAction(_ body: String) -> EscapeAction {
        guard body.hasPrefix("133;") else { return .ignore }
        let rest = body.dropFirst("133;".count)
        guard let kind = rest.first else { return .ignore }
        switch kind {
        case "A": return .promptStart
        case "B": return .commandStart
        case "C": return .outputStart
        case "D":
            // D or D;<exit>
            let parts = rest.split(separator: ";", omittingEmptySubsequences: false)
            if parts.count >= 2, let code = Int(parts[1]) {
                return .commandEnd(exitCode: code)
            }
            return .commandEnd(exitCode: nil)
        default:
            return .ignore
        }
    }

    /// Parses a CSI sequence (after `ESC[`) up to its final byte (`@`...`~`).
    private func parseCSI(_ s: String, paramsStart: String.Index) -> EscapeResult {
        var index = paramsStart
        var params = ""
        while index < s.endIndex {
            if params.count >= Self.maxEscapeLength {
                return .parsed(index, .ignore)
            }
            let char = s[index]
            if let scalar = char.unicodeScalars.first, (0x40...0x7E).contains(scalar.value) {
                let action: EscapeAction
                if Self.csiEntersAltScreen(params), char == "h" {
                    action = .enterAltScreen
                } else if Self.csiEntersAltScreen(params), char == "l" {
                    action = .leaveAltScreen
                } else {
                    action = .ignore
                }
                return .parsed(s.index(after: index), action)
            }
            params.append(char)
            index = s.index(after: index)
        }
        return .incomplete
    }

    /// Whether a CSI private-mode parameter list includes the alt-screen
    /// mode (1049 or legacy 1047). Real terminals batch private modes, e.g.
    /// `ESC[?1049;2004h` (alt screen + bracketed paste), so an exact
    /// `?1049` match would miss them.
    private static func csiEntersAltScreen(_ params: String) -> Bool {
        guard params.hasPrefix("?") else { return false }
        return params.dropFirst()
            .split(separator: ";")
            .contains { $0 == "1049" || $0 == "1047" }
    }

    // MARK: - State transitions

    private mutating func apply(_ action: EscapeAction) {
        switch action {
        case .promptStart:
            finalizeOpenOutput()
            phase = .prompt
        case .commandStart:
            commandBuffer = ""
            phase = .command
        case .outputStart:
            openBlock()
            foldedOutput = ""
            openLine = ""
            phase = .output
        case .commandEnd(let exitCode):
            closeBlock(exitCode: exitCode)
            phase = .idle
        case .enterAltScreen:
            if let openIndex { blocks[openIndex].isInteractive = true }
        case .leaveAltScreen:
            break
        case .ignore:
            break
        }
    }

    private mutating func appendText(_ char: Character) {
        switch phase {
        case .command:
            commandBuffer.append(char)
        case .output:
            // A line terminator commits the open line (folded) to the folded
            // accumulator; everything else extends the open line. "\r\n" is a
            // single Swift grapheme, so it is also a terminator here.
            if char == "\n" || char == "\r\n" {
                foldedOutput += Self.foldLine(openLine)
                foldedOutput += "\n"
                openLine = ""
            } else {
                openLine.append(char)
            }
        case .idle, .prompt:
            break
        }
    }

    private mutating func openBlock() {
        let block = TerminalCommandBlock(
            id: nextID,
            command: commandBuffer.trimmingCharacters(in: .whitespacesAndNewlines),
            output: "",
            exitCode: nil,
            isRunning: true
        )
        nextID += 1
        blocks.append(block)
        openIndex = blocks.count - 1
    }

    private mutating func closeBlock(exitCode: Int?) {
        guard let openIndex else { return }
        blocks[openIndex].output = foldedOutput + Self.foldLine(openLine)
        blocks[openIndex].exitCode = exitCode
        blocks[openIndex].isRunning = false
        self.openIndex = nil
        foldedOutput = ""
        openLine = ""
    }

    private mutating func finalizeOpenOutput() {
        // A new prompt without a D mark (e.g. Ctrl-C, or a shell that skipped
        // D): close the open block with an unknown exit code.
        if openIndex != nil { closeBlock(exitCode: nil) }
    }

    /// Folds carriage-return redraws within ONE line: text after the last
    /// `\r` overwrites from the line start, so a progress bar's repeated
    /// `\r`-redraws collapse to their final state.
    ///
    /// A single trailing `\r` is dropped first: it's the CR of a CRLF whose
    /// `\n` arrived (or will arrive) as the line terminator, including the
    /// case where the CRLF is split across `consume` chunks ("ab\r" then
    /// "\ncd") so the `\r` lands at the end of the open line rather than as a
    /// single "\r\n" grapheme.
    static func foldLine(_ line: String) -> String {
        var line = Substring(line)
        if line.last == "\r" { line = line.dropLast() }
        guard let lastCR = line.lastIndex(of: "\r") else { return String(line) }
        return String(line[line.index(after: lastCR)...])
    }
}
