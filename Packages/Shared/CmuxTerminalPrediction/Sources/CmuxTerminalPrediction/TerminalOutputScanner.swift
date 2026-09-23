/// The classification of remote output that prediction actually depends on.
///
/// This is not a terminal emulator. Ghostty stays the only thing that renders
/// the screen; the scanner exists so the engine can answer one question about
/// each byte the remote sent: does it confirm what the user typed, leave the
/// grid alone, or move the cursor somewhere we cannot predict from?
public enum TerminalOutputSignal: Sendable, Equatable {
    /// A byte that prints at the cursor and advances it one cell.
    case printable(UInt8)
    /// Changes styling or host state but no grid content: SGR and OSC.
    case ignorable
    /// Entered (`true`) or left (`false`) the alternate screen.
    case alternateScreen(Bool)
    /// Anything else. Cursor motion, erases, newlines, unknown escapes: the
    /// screen moved in a way we did not predict.
    case disruptive
}

/// Incremental byte classifier for the PTY output tee.
///
/// libghostty hands cmux output in arbitrary chunks, so escape sequences split
/// across calls. The scanner keeps its parse state between chunks rather than
/// re-synchronising, because a sequence cut in half must not read as two
/// disruptive events and withdraw a correct prediction.
public struct TerminalOutputScanner: Sendable {
    private enum State: Sendable, Equatable {
        case ground
        case escape
        /// Inside a CSI sequence, final byte pending. Its parameter bytes
        /// live in `parameters`, not here, so collecting one is an in-place
        /// append rather than a copy of everything collected so far.
        case controlSequence
        /// Operating system command, running to BEL or ST.
        case operatingSystemCommand
        /// Saw ESC inside an OSC: the next byte decides ST versus a new escape.
        case operatingSystemCommandEscape
    }

    private var state: State = .ground
    /// Parameter and intermediate bytes of the current CSI sequence, up to
    /// `maximumParameterBytes`. The remote controls how long a sequence is, and
    /// classification only ever compares against short mode numbers, so bytes
    /// past the cap are counted as overflow rather than stored.
    private var parameters: [UInt8] = []
    private var parametersOverflowed = false
    private static let maximumParameterBytes = 16

    public init() {}

    /// Classify one chunk. Returns one signal per byte-or-sequence, in order.
    public mutating func scan(_ bytes: some Sequence<UInt8>) -> [TerminalOutputSignal] {
        var signals: [TerminalOutputSignal] = []
        for byte in bytes {
            if let signal = consume(byte) {
                signals.append(signal)
            }
        }
        return signals
    }

    private mutating func consume(_ byte: UInt8) -> TerminalOutputSignal? {
        switch state {
        case .ground:
            if byte == 0x1B {
                state = .escape
                return nil
            }
            if (0x20...0x7E).contains(byte) {
                return .printable(byte)
            }
            // C1 and the rest of C0 (newline, carriage return, bell, tab) all
            // move the cursor or the screen.
            return .disruptive

        case .escape:
            switch byte {
            case UInt8(ascii: "["):
                state = .controlSequence
                parameters.removeAll(keepingCapacity: true)
                parametersOverflowed = false
                return nil
            case UInt8(ascii: "]"):
                state = .operatingSystemCommand
                return nil
            default:
                state = .ground
                return .disruptive
            }

        case .controlSequence:
            // Parameter and intermediate bytes accumulate; 0x40...0x7E ends it.
            if (0x20...0x3F).contains(byte) {
                if parameters.count < Self.maximumParameterBytes {
                    parameters.append(byte)
                } else {
                    parametersOverflowed = true
                }
                return nil
            }
            state = .ground
            guard (0x40...0x7E).contains(byte) else { return .disruptive }
            return Self.classifyControlSequence(
                parameters: parameters,
                overflowed: parametersOverflowed,
                final: byte
            )

        case .operatingSystemCommand:
            if byte == 0x07 {
                state = .ground
                return .ignorable
            }
            if byte == 0x1B {
                state = .operatingSystemCommandEscape
            }
            return nil

        case .operatingSystemCommandEscape:
            if byte == UInt8(ascii: "\\") {
                state = .ground
                return .ignorable
            }
            // Not a string terminator, so the OSC is still running.
            state = .operatingSystemCommand
            return nil
        }
    }

    private static func classifyControlSequence(
        parameters: [UInt8],
        overflowed: Bool,
        final: UInt8
    ) -> TerminalOutputSignal {
        // SGR only repaints existing cells, which is how shells colour the line
        // they are echoing. Treating it as disruptive would withdraw a correct
        // prediction on every syntax-highlighted keystroke.
        if final == UInt8(ascii: "m") { return .ignorable }

        guard final == UInt8(ascii: "h") || final == UInt8(ascii: "l") else { return .disruptive }
        // A truncated parameter list could spuriously match a mode below, and
        // no alternate-screen form is anywhere near the cap.
        guard !overflowed else { return .disruptive }
        let entering = final == UInt8(ascii: "h")
        // 1049 is the modern alternate screen; 47 and 1047 are the older forms
        // still emitted by some remotes.
        for mode in ["?1049", "?47", "?1047"] where parameters.elementsEqual(mode.utf8) {
            return .alternateScreen(entering)
        }
        // Any other private mode change (bracketed paste, mouse reporting,
        // application cursor keys) means the remote is switching input
        // conventions, so stop predicting what its echo will look like.
        return .disruptive
    }
}
