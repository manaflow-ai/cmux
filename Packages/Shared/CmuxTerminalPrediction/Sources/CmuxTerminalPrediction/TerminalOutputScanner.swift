public import Foundation

/// The classification of remote output that prediction actually depends on.
///
/// This is not a terminal emulator. Ghostty stays the only thing that renders
/// the screen; the scanner exists so the engine can answer one question about
/// each byte the remote sent: does it confirm what the user typed, leave the
/// grid alone, or move the cursor somewhere we cannot predict from?
public enum TerminalOutputSignal: Sendable, Equatable {
    /// A byte that prints at the cursor and advances it one cell.
    case printable(UInt8)
    /// Changes styling or host state but no grid content: SGR, and the
    /// string sequences (OSC, DCS, APC, PM, SOS) whatever their payload.
    case ignorable
    /// Entered (`true`) or left (`false`) the alternate screen.
    case alternateScreen(Bool)
    /// Moved the cursor exactly one cell left: BS, `CSI D` or `CSI 1 D`.
    ///
    /// Disruptive unless the engine is waiting for the erase of a glyph the
    /// user backspaced over; this is the first half of every common form.
    case cursorLeft
    /// Moved the cursor left by more than one cell: `CSI n D`, n > 1. Line
    /// editors do this to rewrite text they already echoed (zsh recolouring
    /// a word), which only the engine's model of the line can tell apart from
    /// a redraw.
    case cursorLeftBy(Int)
    /// Cleared the cell under the cursor without moving it: `CSI K`,
    /// `CSI 0 K`, `CSI P` or `CSI 1 P`. The same caveat as `cursorLeft`.
    case clearAtCursor
    /// Anything else. Cursor motion, erases, newlines, unknown escapes, and
    /// images (kitty graphics, sixel), which move the cursor past them: the
    /// screen moved in a way we did not predict.
    case disruptive
}

/// What a chunk did, as far as a surface with nothing in flight cares.
public struct TerminalOutputSkim: Sendable, Equatable {
    /// Whether anything but styling and host state went by.
    public var touchedTheScreen = false
    /// The last alternate-screen switch, if any.
    public var alternateScreen: Bool?

    public init(touchedTheScreen: Bool = false, alternateScreen: Bool? = nil) {
        self.touchedTheScreen = touchedTheScreen
        self.alternateScreen = alternateScreen
    }
}

/// Incremental byte classifier for the PTY output tee.
///
/// libghostty hands cmux output in arbitrary chunks, so escape sequences split
/// across calls. The scanner keeps its parse state between chunks rather than
/// re-synchronising, because a sequence cut in half must not read as two
/// disruptive events and withdraw a correct prediction.
public struct TerminalOutputScanner: Sendable {
    /// The string sequences: a payload of arbitrary bytes, none of which
    /// reach the grid, running to a terminator.
    private enum ControlString: Sendable, Equatable {
        /// OSC, which also ends at BEL.
        case operatingSystemCommand
        /// DCS, SOS, PM and APC (`ESC P`, `ESC X`, `ESC ^`, `ESC _`), which end
        /// at ST, at any other ESC, or at a C1 byte. Ghostty passes BEL through
        /// as payload here, so ending on it would read the rest of, say, a
        /// sixel image as printed text.
        case other
    }

    private enum State: Sendable, Equatable {
        case ground
        case escape
        /// After `ESC` and at least one intermediate byte (0x20...0x2F), final
        /// byte pending. Holds the intermediate when there was exactly one,
        /// 0x20 when there were more.
        case escapeIntermediate(UInt8)
        /// Inside a CSI sequence, final byte pending. Its parameter bytes
        /// live in `parameters`, not here, so collecting one is an in-place
        /// append rather than a copy of everything collected so far.
        case controlSequence
        /// Inside a string sequence, terminator pending.
        case controlString(ControlString)
        /// Saw ESC inside a string sequence: the next byte decides whether it
        /// was ST.
        case controlStringEscape(ControlString)
    }

    private var state: State = .ground
    /// The byte after `ESC` that opened the current string sequence, and
    /// whether its header is still being read. A kitty graphics command
    /// (`ESC _ G`) or a sixel image (`ESC P ... q`) places an image and moves
    /// the cursor past it, so it ends as `.disruptive`, not `.ignorable`.
    private var stringIntroducer: UInt8 = 0
    private var isReadingStringHeader = false
    private var stringIsImage = false
    /// Between a cursor save (`ESC 7`, `CSI s`) and its restore, whatever is
    /// drawn happens somewhere else: a status line or clock repainting. The
    /// restore puts the cursor back, so none of it is disruptive. Bounded, in
    /// case a save is never restored.
    private var detourBytes: Int?
    private static let maximumDetourBytes = 4_096
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
            if let signal = consumeOutsideDetour(byte) {
                signals.append(signal)
            }
        }
        return signals
    }

    /// Classify one byte: the signal it completes, if any.
    public mutating func next(_ byte: UInt8) -> TerminalOutputSignal? {
        consumeOutsideDetour(byte)
    }

    /// Reads a chunk only for what a surface with nothing in flight needs:
    /// whether it touched the screen, and alternate-screen switches. Keeps
    /// the parse state exactly as `scan` would, but jumps over plain text.
    public mutating func skim(_ bytes: UnsafeBufferPointer<UInt8>) -> TerminalOutputSkim {
        var skim = TerminalOutputSkim()
        guard let base = bytes.baseAddress else { return skim }
        var index = 0
        let count = bytes.count
        while index < count {
            if state == .ground, detourBytes == nil, skim.touchedTheScreen {
                // Text, controls and newlines only touch the screen, which is
                // already known; only an escape can switch screens.
                guard let found = memchr(base + index, 0x1B, count - index) else { break }
                index = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
            }
            switch consumeOutsideDetour(base[index]) {
            case nil, .ignorable?:
                break
            case .alternateScreen(let entered)?:
                skim.alternateScreen = entered
                skim.touchedTheScreen = true
            case _?:
                skim.touchedTheScreen = true
            }
            index += 1
        }
        return skim
    }

    private mutating func consumeOutsideDetour(_ byte: UInt8) -> TerminalOutputSignal? {
        let signal = consume(byte)
        guard let bytes = detourBytes else { return signal }
        if case .alternateScreen? = signal { return signal }
        if bytes >= Self.maximumDetourBytes {
            detourBytes = nil
            return .disruptive
        }
        detourBytes = bytes + 1
        return nil
    }

    private mutating func openString(_ introducer: UInt8) {
        stringIntroducer = introducer
        isReadingStringHeader = introducer == UInt8(ascii: "_") || introducer == UInt8(ascii: "P")
        stringIsImage = false
    }

    private mutating func readStringHeader(_ byte: UInt8) {
        switch stringIntroducer {
        case UInt8(ascii: "_"):
            stringIsImage = byte == UInt8(ascii: "G")
            isReadingStringHeader = false
        default:
            // DCS parameters, then its final byte: `q` is sixel.
            if (0x30...0x3B).contains(byte) { return }
            stringIsImage = byte == UInt8(ascii: "q")
            isReadingStringHeader = false
        }
    }

    private var endOfString: TerminalOutputSignal {
        stringIsImage ? .disruptive : .ignorable
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
            if byte == 0x08 { return .cursorLeft }
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
                state = .controlString(.operatingSystemCommand)
                openString(byte)
                return nil
            case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
                state = .controlString(.other)
                openString(byte)
                return nil
            case UInt8(ascii: "7"):
                state = .ground
                detourBytes = 0
                return nil
            case UInt8(ascii: "8"):
                state = .ground
                detourBytes = nil
                return .ignorable
            case 0x1B:
                // Another ESC restarts the escape, as it does in ghostty.
                return nil
            case UInt8(ascii: "\\"):
                // A string terminator with no string open changes nothing.
                state = .ground
                return .ignorable
            case 0x20...0x2F:
                // Intermediates, as in `ESC ( B`, the start of xterm's sgr0.
                state = .escapeIntermediate(byte)
                return nil
            default:
                state = .ground
                return .disruptive
            }

        case .escapeIntermediate(let intermediate):
            if (0x20...0x2F).contains(byte) {
                state = .escapeIntermediate(0x20)
                return nil
            }
            if byte == 0x1B {
                state = .escape
                return nil
            }
            state = .ground
            guard (0x30...0x7E).contains(byte) else { return .disruptive }
            // Designating ASCII into G0-G3 changes no cell. Any other set (DEC
            // line drawing, say) changes how later printables render.
            let designatesASCII = (0x28...0x2B).contains(intermediate) && byte == UInt8(ascii: "B")
            return designatesASCII ? .ignorable : .disruptive

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
            if parameters.isEmpty, byte == UInt8(ascii: "s") {
                detourBytes = 0
                return nil
            }
            if parameters.isEmpty, byte == UInt8(ascii: "u") {
                detourBytes = nil
                return .ignorable
            }
            return Self.classifyControlSequence(
                parameters: parameters,
                overflowed: parametersOverflowed,
                final: byte
            )

        case .controlString(let kind):
            switch byte {
            case 0x07 where kind == .operatingSystemCommand:
                state = .ground
                return endOfString
            case 0x18, 0x1A:
                // CAN and SUB abort the sequence and are executed as controls.
                state = .ground
                return .disruptive
            case 0x1B:
                state = .controlStringEscape(kind)
                return nil
            case 0x9C where kind == .other:
                // The 8-bit string terminator.
                state = .ground
                return endOfString
            case 0x80...0x9F where kind == .other:
                // Ghostty leaves a DCS, APC, PM or SOS at any other C1 byte.
                state = .ground
                return .disruptive
            default:
                if isReadingStringHeader { readStringHeader(byte) }
                return nil
            }

        case .controlStringEscape:
            if byte == UInt8(ascii: "\\") {
                state = .ground
                return endOfString
            }
            if stringIsImage {
                // Left for a new sequence, the image was still placed.
                state = .escape
                _ = consume(byte)
                return .disruptive
            }
            // Ghostty leaves the string at any ESC, not only at ST, and
            // parses the next byte as the start of a new sequence. Staying in
            // the string here would miss everything ghostty then applies.
            state = .escape
            return consume(byte)
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

        // The halves of a line editor erasing one character. Only the counts
        // that mean one cell qualify; anything wider is a redraw. An
        // overflowed list holds the capped bytes, so it never matches.
        let isDefaultOrOne = parameters.isEmpty || parameters.elementsEqual("1".utf8)
        let isDefaultOrZero = parameters.isEmpty || parameters.elementsEqual("0".utf8)
        switch final {
        case UInt8(ascii: "D") where isDefaultOrOne:
            return .cursorLeft
        case UInt8(ascii: "D") where !overflowed && parameters.count <= 3
            && parameters.allSatisfy({ (0x30...0x39).contains($0) }):
            let count = parameters.reduce(0) { $0 * 10 + Int($1 - 0x30) }
            return count <= 1 ? .cursorLeft : .cursorLeftBy(count)
        case UInt8(ascii: "P") where isDefaultOrOne, UInt8(ascii: "K") where isDefaultOrZero:
            return .clearAtCursor
        default:
            break
        }

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
