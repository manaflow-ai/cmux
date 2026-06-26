extension TerminalSurface {
    /// Returns the byte-like scalar length for a complete terminal control sequence.
    static func terminalControlSequenceLength(
        _ scalars: [Unicode.Scalar],
        from start: Int
    ) -> Int? {
        guard start + 1 < scalars.count, scalars[start].value == 0x1B else { return nil }

        switch scalars[start + 1].value {
        case 0x5B: // CSI: ESC [ ... final-byte
            return csiControlSequenceLength(scalars, from: start)
        case 0x5D: // OSC: ESC ] ... (BEL | ST)
            return stringControlSequenceLength(scalars, from: start, terminatesWithBEL: true)
        case 0x50, 0x5E, 0x5F: // DCS / PM / APC: ESC P/^/_ ... ST
            return stringControlSequenceLength(scalars, from: start, terminatesWithBEL: false)
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
