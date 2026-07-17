/// Iterates UTF-8 lines without first allocating an array proportional to the
/// source line count. Byte scanning keeps CRLF from becoming one Swift grapheme.
struct UnifiedDiffLineSequence: Sequence, IteratorProtocol {
    private var remaining: Substring.UTF8View

    init(_ source: String) {
        remaining = source[...].utf8
    }

    mutating func next() -> String? {
        guard !remaining.isEmpty else { return nil }
        guard let newline = remaining.firstIndex(of: 0x0A) else {
            defer { remaining = remaining[remaining.endIndex...] }
            return String(decoding: remaining, as: UTF8.self)
        }
        let bytes = remaining[..<newline]
        remaining = remaining[remaining.index(after: newline)...]
        if bytes.last == 0x0D {
            return String(decoding: bytes.dropLast(), as: UTF8.self)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
