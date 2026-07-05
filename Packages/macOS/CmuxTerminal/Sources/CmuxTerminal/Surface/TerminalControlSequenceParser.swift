struct TerminalControlSequenceParser {
    private let scalars: [Unicode.Scalar]

    init(scalars: [Unicode.Scalar]) {
        self.scalars = scalars
    }

    /// Returns the scalar length of a complete control sequence that must be
    /// routed to the terminal parser (`process_output`) rather than delivered to
    /// the PTY: OSC/DCS/PM/APC strings, and the CSI DSR *queries* (`ESC[6n`
    /// cursor position, `ESC[?6n` DEC cursor position, `ESC[5n` status) the
    /// emulator must answer. Everything
    /// else — interactive CSI input (function keys, kitty-keyboard, mouse,
    /// arbitrary `terminal.input`) and terminal-to-application *responses* (CPR
    /// `ESC[…R`, DSR results `ESC[0n`/`ESC[3n`) — is deliberately not matched so
    /// it stays on the input path toward the foreground program. Returns nil for
    /// anything else. See #5763: the emulator was failing to answer `ESC[6n`.
    func terminalControlSequenceLength(from start: Int) -> Int? {
        guard start + 1 < scalars.count, scalars[start].value == 0x1B else { return nil }

        switch scalars[start + 1].value {
        case 0x5B: // CSI: ESC [ ... — only DSR queries the emulator answers
            return csiDeviceStatusQueryLength(from: start)
        case 0x5D: // OSC: ESC ] ... (BEL | ST)
            return stringControlSequenceLength(from: start, terminatesWithBEL: true)
        case 0x50, 0x5E, 0x5F: // DCS / PM / APC: ESC P/^/_ ... ST
            return stringControlSequenceLength(from: start, terminatesWithBEL: false)
        default:
            return nil
        }
    }

    /// Length of a complete CSI sequence *iff* it is a Device Status Report
    /// *query* the emulator must answer: `CSI 5 n` (status), `CSI 6 n` (cursor
    /// position, the sequence #5763 needs answered with a CPR), or `CSI ? 6 n`
    /// (DEC private cursor position). These narrow forms have no interactive-key
    /// collision.
    ///
    /// Only queries match. Terminal-to-application *responses* — CPR
    /// `CSI {row};{col} R`, DSR results `CSI 0 n` / `CSI 3 n` — and interactive
    /// keys that share those finals (xterm Shift+F3 is `CSI 1 ; 2 R`) are bytes
    /// the foreground PTY program is waiting for, so they stay on the input path.
    /// Returns nil for any non-query CSI.
    private func csiDeviceStatusQueryLength(from start: Int) -> Int? {
        guard let length = csiControlSequenceLength(from: start) else { return nil }
        guard scalars[start + length - 1].value == 0x6E else { return nil }
        if length == 4 {
            switch scalars[start + 2].value {
            case 0x35, 0x36: // "5" (status), "6" (cursor position)
                return length
            default:
                return nil
            }
        }
        if length == 5,
           scalars[start + 2].value == 0x3F, // "?"
           scalars[start + 3].value == 0x36 { // "6" (DEC cursor position)
            return length
        }
        return nil
    }

    /// Finds the terminator for a complete CSI sequence.
    private func csiControlSequenceLength(from start: Int) -> Int? {
        var index = start + 2
        while index < scalars.count {
            let value = scalars[index].value
            if (0x40...0x7E).contains(value) {
                return index - start + 1
            }
            guard (0x20...0x3F).contains(value) else {
                return nil
            }
            index += 1
        }
        return nil
    }

    /// Finds the terminator for ESC-prefixed string controls without accepting partial sequences.
    private func stringControlSequenceLength(from start: Int, terminatesWithBEL: Bool) -> Int? {
        var index = start + 2
        while index < scalars.count {
            let value = scalars[index].value
            if terminatesWithBEL, value == 0x07 {
                return index - start + 1
            }
            if value == 0x1B,
               index + 1 < scalars.count,
               scalars[index + 1].value == 0x5C {
                return index - start + 2
            }
            index += 1
        }
        return nil
    }
}
