extension TerminalSurface {
    /// Returns the scalar length of a complete control sequence that must be
    /// routed to the terminal parser (`process_output`) rather than delivered to
    /// the PTY: OSC/DCS/PM/APC strings, and the CSI cursor reports/queries
    /// (DSR/CPR) the emulator answers. Interactive CSI input — function keys,
    /// kitty-keyboard, mouse, arbitrary `terminal.input` — is deliberately not
    /// matched so it stays on the input path. Returns nil for anything else.
    /// See #5763: only cursor reports/queries were being misrouted.
    static func terminalControlSequenceLength(
        _ scalars: [Unicode.Scalar],
        from start: Int
    ) -> Int? {
        guard start + 1 < scalars.count, scalars[start].value == 0x1B else { return nil }

        switch scalars[start + 1].value {
        case 0x5B: // CSI: ESC [ ... — only cursor reports/queries (DSR/CPR)
            return csiReportSequenceLength(scalars, from: start)
        case 0x5D: // OSC: ESC ] ... (BEL | ST)
            return stringControlSequenceLength(scalars, from: start, terminatesWithBEL: true)
        case 0x50, 0x5E, 0x5F: // DCS / PM / APC: ESC P/^/_ ... ST
            return stringControlSequenceLength(scalars, from: start, terminatesWithBEL: false)
        default:
            return nil
        }
    }

    /// Length of a complete CSI sequence *iff* its final byte marks a cursor
    /// report/query the emulator must consume or answer — DSR (`n`) or CPR (`R`).
    /// Both finals are unambiguous terminal reports (no interactive key encodes a
    /// CSI ending in `n` or `R`), so narrowing to them keeps the #5763 cursor-sync
    /// fix while leaving function keys, kitty-keyboard, mouse, and other raw CSI
    /// input on the PTY path. Returns nil for any non-report CSI.
    private static func csiReportSequenceLength(
        _ scalars: [Unicode.Scalar],
        from start: Int
    ) -> Int? {
        guard let length = csiControlSequenceLength(scalars, from: start) else { return nil }
        switch scalars[start + length - 1].value {
        case 0x6E, 0x52: // n (DSR), R (CPR)
            return length
        default:
            return nil
        }
    }

    /// Finds the terminator for a complete CSI sequence.
    private static func csiControlSequenceLength(
        _ scalars: [Unicode.Scalar],
        from start: Int
    ) -> Int? {
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
    private static func stringControlSequenceLength(
        _ scalars: [Unicode.Scalar],
        from start: Int,
        terminatesWithBEL: Bool
    ) -> Int? {
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
