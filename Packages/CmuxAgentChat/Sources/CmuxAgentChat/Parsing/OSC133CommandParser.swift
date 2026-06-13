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
public final class OSC133CommandParser {
    /// The command blocks parsed so far, oldest first.
    public private(set) var blocks: [TerminalCommandBlock] = []

    private enum Phase { case idle, prompt, command, output }
    private var phase: Phase = .idle
    private var commandBuffer = ""
    private var outputBuffer = ""
    private var pending = ""
    private var nextID = 0
    private var openIndex: Int?

    /// Creates an empty parser.
    public init() {}

    /// Feeds a chunk of raw terminal output through the state machine.
    ///
    /// - Parameter text: A slice of the PTY stream, any length.
    public func consume(_ text: String) {
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
                // Hold the partial escape until the next chunk completes it.
                pending = String(stream[index...])
                return
            }
        }
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
            let char = s[index]
            if let scalar = char.unicodeScalars.first, (0x40...0x7E).contains(scalar.value) {
                let action: EscapeAction
                switch params {
                case "?1049": action = char == "h" ? .enterAltScreen : (char == "l" ? .leaveAltScreen : .ignore)
                default: action = .ignore
                }
                return .parsed(s.index(after: index), action)
            }
            params.append(char)
            index = s.index(after: index)
        }
        return .incomplete
    }

    // MARK: - State transitions

    private func apply(_ action: EscapeAction) {
        switch action {
        case .promptStart:
            finalizeOpenOutput()
            phase = .prompt
        case .commandStart:
            commandBuffer = ""
            phase = .command
        case .outputStart:
            openBlock()
            outputBuffer = ""
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

    private func appendText(_ char: Character) {
        switch phase {
        case .command:
            commandBuffer.append(char)
        case .output:
            outputBuffer.append(char)
            blocks[openIndex!].output = Self.foldCarriageReturns(outputBuffer)
        case .idle, .prompt:
            break
        }
    }

    private func openBlock() {
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

    private func closeBlock(exitCode: Int?) {
        guard let openIndex else { return }
        blocks[openIndex].output = Self.foldCarriageReturns(outputBuffer)
        blocks[openIndex].exitCode = exitCode
        blocks[openIndex].isRunning = false
        self.openIndex = nil
        outputBuffer = ""
    }

    private func finalizeOpenOutput() {
        // A new prompt without a D mark (e.g. Ctrl-C, or a shell that skipped
        // D): close the open block with an unknown exit code.
        if openIndex != nil { closeBlock(exitCode: nil) }
    }

    /// Folds carriage-return redraws: within a line, text after a `\r` (not
    /// followed by `\n`) overwrites from the line start, so a progress bar's
    /// repeated redraws collapse to the final state.
    static func foldCarriageReturns(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let lastCR = line.lastIndex(of: "\r") else { return line }
                return line[line.index(after: lastCR)...]
            }
            .joined(separator: "\n")
    }
}
