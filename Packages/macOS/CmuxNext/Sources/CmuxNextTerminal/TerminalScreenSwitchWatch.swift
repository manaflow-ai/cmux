import Foundation

/// Which parsed output chunks need a read of Ghostty's alternate screen (``TerminalOutputLane``, RESIZE P0 15): only a
/// DEC private mode set or reset (ESC `[` `?` ... `h`/`l`: 1049, 1047, 47) or a full reset (ESC `c`) switches the screen,
/// so a chunk with neither introducer costs one byte scan and no lock. An introducer split across two chunks is read at
/// the second.
nonisolated struct TerminalScreenSwitchWatch {
    /// The last chunk ended inside an escape introducer (ESC, or ESC `[`): the next chunk's start may finish a mode change.
    private var endsInEscape = false

    /// Whether the screen must be read after the lane parsed `data` (nil: a snapshot restore, which can change anything).
    mutating func needsRead(after data: Data?) -> Bool {
        guard let data else { return true }
        let (changes, endsInEscape) = Self.mayChangeScreen(data, afterEscape: endsInEscape)
        self.endsInEscape = endsInEscape
        return changes
    }

    /// The read that ``needsRead(after:)`` asked for ran; `read` is false when Ghostty could not read the screen.
    mutating func readFinished(_ read: Bool) {}

    /// Whether `data` holds an introducer of a screen switch (ESC `[` `?`, or ESC `c`), counting a chunk before it that
    /// ended inside one (`afterEscape`), and whether `data` itself ends inside one.
    static func mayChangeScreen(_ data: Data, afterEscape: Bool) -> (changes: Bool, endsInEscape: Bool) {
        data.withUnsafeBytes { raw -> (Bool, Bool) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            guard count > 0, let base = bytes.baseAddress else { return (false, afterEscape) }
            let ends = bytes[count - 1] == 0x1B || (count >= 2 && bytes[count - 2] == 0x1B && bytes[count - 1] == 0x5B)
            if afterEscape, bytes[0] == 0x5B || bytes[0] == 0x3F || bytes[0] == 0x63 { return (true, ends) }
            var index = 0
            // memchr to each ESC: output with no escapes is one scan.
            while index < count, let found = memchr(base + index, 0x1B, count - index) {
                index = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(found))
                let next = index + 1 < count ? bytes[index + 1] : 0
                if next == 0x63 { return (true, ends) }
                if next == 0x5B, index + 2 < count, bytes[index + 2] == 0x3F { return (true, ends) }
                index += 1
            }
            return (false, ends)
        }
    }
}
