/// A text's ASCII bytes, lowercased, for the literal gate of ``SentryRegexPattern``: a rule whose
/// required literals are all absent from the text cannot match it, so its regex does not run.
///
/// Most scrubbed strings (breadcrumb messages, context values, frame and image paths) hold no secret,
/// and each one ran every rule's case-insensitive ICU regex: the scrub of one lag-spike event cost
/// 8% of a core of the NIGHTLY app (cmuxterm-hq perf hotspot `SentryScrubber.redactSecrets`). The gate
/// costs one pass over the bytes and a few substring checks.
///
/// The gate is sound only for ASCII text: with ICU's case folding a non-ASCII character can match an
/// ASCII pattern letter (the Kelvin sign U+212A matches `k`, `ſ` matches `s`). A text with any non-ASCII
/// byte has no probe bytes, and every rule runs on it.
struct SentryLiteralProbe {
    /// The text's bytes with `A`-`Z` lowercased, or nil when it holds a non-ASCII byte.
    private let bytes: [UInt8]?
    /// Which byte values occur in ``bytes`` (bit `b & 63` of word `b >> 6`).
    private let present: (UInt64, UInt64)

    init(_ text: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        var low: UInt64 = 0
        var high: UInt64 = 0
        for byte in text.utf8 {
            guard byte < 0x80 else {
                self.bytes = nil
                self.present = (0, 0)
                return
            }
            let lowered = byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
            bytes.append(lowered)
            if lowered < 64 { low |= 1 << UInt64(lowered) } else { high |= 1 << UInt64(lowered - 64) }
        }
        self.bytes = bytes
        self.present = (low, high)
    }

    /// Whether the text may hold `literal`: true for a non-ASCII text.
    /// - Parameter literal: Lowercase ASCII bytes.
    func mayContain(_ literal: [UInt8]) -> Bool {
        guard let bytes else { return true }
        guard let first = literal.first else { return true }
        guard has(first) else { return false }
        if literal.count == 1 { return true }
        guard literal.count <= bytes.count else { return false }
        return bytes.withUnsafeBufferPointer { text in
            literal.withUnsafeBufferPointer { needle in
                var index = 0
                let last = text.count - needle.count
                while index <= last {
                    if text[index] == needle[0] {
                        var offset = 1
                        while offset < needle.count, text[index + offset] == needle[offset] { offset += 1 }
                        if offset == needle.count { return true }
                    }
                    index += 1
                }
                return false
            }
        }
    }

    private func has(_ byte: UInt8) -> Bool {
        byte < 64 ? present.0 & (1 << UInt64(byte)) != 0 : present.1 & (1 << UInt64(byte - 64)) != 0
    }
}
