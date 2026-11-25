import Foundation

/// Which parsed output chunks need a read of Ghostty's alternate screen (``TerminalOutputLane``, RESIZE P0 15): only a
/// DEC private mode set or reset (ESC `[` `?` ... `h`/`l`: 1049, 1047, 47) or a full reset (ESC `c`) switches the screen,
/// so a chunk with neither introducer costs one byte scan and no lock. A PTY read can cut a switch anywhere: a chunk that
/// ends inside one (ESC, ESC `[`, or ESC `[` `?` and its parameters with no final byte) is read again after the next
/// chunk, and so is a read that failed (review of #38206 at 17154838e7b, P2 2 and 3).
nonisolated struct TerminalScreenSwitchWatch {
    /// The last chunk ended inside an escape that may still switch the screen: the next chunk ends it (or goes on with it).
    private var endsInEscape = false
    /// The last read failed (an unlocked grid's resize was in flight): the next chunk is read, whatever it holds.
    private var readPending = false

    /// Whether the screen must be read after the lane parsed `data` (nil: a snapshot restore, which can change anything).
    mutating func needsRead(after data: Data?) -> Bool {
        guard let data else { return true }
        let (changes, endsInEscape) = Self.mayChangeScreen(data, afterEscape: endsInEscape)
        self.endsInEscape = endsInEscape
        return changes || readPending
    }

    /// The read that ``needsRead(after:)`` asked for ran; `read` is false when Ghostty could not read the screen, and the
    /// next chunk is read again.
    mutating func readFinished(_ read: Bool) { readPending = !read }

    /// Whether `data` may have switched the screen: it holds an introducer (ESC `[` `?`, or ESC `c`), or the chunk before
    /// it ended inside one (`afterEscape`); and whether `data` itself ends inside one.
    static func mayChangeScreen(_ data: Data, afterEscape: Bool) -> (changes: Bool, endsInEscape: Bool) {
        data.withUnsafeBytes { raw -> (Bool, Bool) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            guard count > 0, let base = bytes.baseAddress else { return (false, afterEscape) }
            let ends = endsOpen(bytes, afterEscape: afterEscape)
            if afterEscape { return (true, ends) }
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

    /// Whether `bytes` ends inside an escape that may still switch the screen: ESC alone, ESC `[` alone, or ESC `[` `?`
    /// and parameter bytes (0x20-0x3F) with no final byte. A chunk of parameter bytes only goes on with the escape the
    /// chunk before left open (`afterEscape`). An ordinary CSI cut in its parameters (an SGR, ESC `[` `3`) is not open:
    /// it cannot switch the screen. Reads only the chunk's tail.
    private static func endsOpen(_ bytes: UnsafeBufferPointer<UInt8>, afterEscape: Bool) -> Bool {
        var index = bytes.count - 1
        while index >= 0, (0x20...0x3F).contains(bytes[index]) { index -= 1 }
        guard index >= 0 else { return afterEscape }
        let parameters = bytes.count - 1 - index
        switch bytes[index] {
        case 0x1B:
            return parameters == 0
        case 0x5B:
            let opened = index >= 1 ? bytes[index - 1] == 0x1B : afterEscape
            return opened && (parameters == 0 || bytes[index + 1] == 0x3F)
        default:
            return false
        }
    }
}
