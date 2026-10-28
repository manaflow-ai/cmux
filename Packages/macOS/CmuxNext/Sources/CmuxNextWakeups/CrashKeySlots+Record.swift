/// The crash record line of the keys: what the crash path writes into `run.crashkeys` and
/// `CrashKeys(record:)` in CmuxNextCrashReporting reads back.
extension CrashKeySlots {
    /// Writes the crash record line of the block at `address` into `buffer`, loading each word straight from
    /// the block: no snapshot, no generic helper, no allocation, no lock. The crash path's writer
    /// (`CrashReporter` in CmuxNextCrashReporting) runs it in a fatal-signal handler.
    ///
    /// - Returns: The number of bytes written.
    public static func writeRecord(wordsAt address: UInt, into buffer: UnsafeMutableRawBufferPointer) -> Int {
        writeRecord(into: buffer) { word($0, at: address) }
    }

    /// Writes the record line of the words `word` returns (index `0..<wordCount`) into `buffer` (at least
    /// ``maxRecordBytes`` bytes for a whole line; a shorter buffer gets a cut line).
    ///
    /// The line is `crash_keys` and then `name=value` words, every value a decimal number:
    /// `crash_keys action_id=1234 pane_kind=1 cef_state=2 daemon_epoch=3 hung_threads=1 hung_kind_0=3`. Keys at
    /// 0 are left out, and hung threads go by kind only (a thread port means nothing after the process ended).
    /// The Rust crate's `Snapshot::write_line` (cmux-tui/crates/cmux-panic-log/src/crash_keys.rs) writes the same.
    ///
    /// - Returns: The number of bytes written.
    public static func writeRecord(into buffer: UnsafeMutableRawBufferPointer, word: (Int) -> UInt64) -> Int {
        var line = RecordWriter(buffer)
        line.append("crash_keys")
        var key = 0
        while key < firstHungWord {
            line.field(keyName(key), word(key))
            key += 1
        }
        var count: UInt64 = 0, index = 0
        while index < hungThreadCapacity {
            if word(firstHungWord + index) & 0xFFFF_FFFF != 0 { count += 1 }
            index += 1
        }
        line.field("hung_threads", count)
        var named: UInt64 = 0
        index = 0
        while index < hungThreadCapacity {
            let entry = word(firstHungWord + index)
            if entry & 0xFFFF_FFFF != 0 {
                line.append(" hung_kind_")
                line.decimal(named)
                line.byte(0x3D)
                line.decimal((entry >> 32) & 0xFF)
                named += 1
            }
            index += 1
        }
        line.byte(0x0A)
        return line.count
    }

    /// The longest line ``writeRecord(into:word:)`` writes, its newline included (the longest possible line is
    /// under 300 bytes).
    public static var maxRecordBytes: Int { 512 }

    /// The record name of the key in word `index` (`0..<4`).
    static func keyName(_ index: Int) -> StaticString {
        switch index {
        case 0: "action_id"
        case 1: "pane_kind"
        case 2: "cef_state"
        default: "daemon_epoch"
        }
    }
}

/// Appends ASCII to a caller's buffer with no allocation; stops at the buffer's end. Loops with `while` over
/// raw pointers only: it runs in a fatal-signal handler, where an unspecialized generic could instantiate
/// type metadata (a lock and an allocation).
private struct RecordWriter {
    let buffer: UnsafeMutableRawBufferPointer
    private(set) var count = 0

    init(_ buffer: UnsafeMutableRawBufferPointer) {
        self.buffer = buffer
    }

    mutating func byte(_ value: UInt8) {
        guard count < buffer.count, let base = buffer.baseAddress else { return }
        base.storeBytes(of: value, toByteOffset: count, as: UInt8.self)
        count += 1
    }

    /// `text` must be a multi-character literal (a pointer representation; every caller passes one).
    mutating func append(_ text: StaticString) {
        guard text.hasPointerRepresentation else { return }
        let start = text.utf8Start
        var index = 0
        while index < text.utf8CodeUnitCount {
            byte(start[index])
            index += 1
        }
    }

    /// ` name=value`, left out when `value` is 0.
    mutating func field(_ name: StaticString, _ value: UInt64) {
        guard value != 0 else { return }
        byte(0x20)
        append(name)
        byte(0x3D)
        decimal(value)
    }

    mutating func decimal(_ value: UInt64) {
        var divisor: UInt64 = 1
        while value / divisor >= 10 { divisor *= 10 }
        var rest = value
        while divisor > 0 {
            byte(0x30 + UInt8(truncatingIfNeeded: rest / divisor))
            rest %= divisor
            divisor /= 10
        }
    }
}
