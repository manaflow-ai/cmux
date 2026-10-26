import Foundation

/// The Files filter field's test: does a name contain the typed text,
/// ignoring case and accents?
///
/// ASCII text against ASCII names compares bytes with no allocation, so
/// filtering 100 000 names per keystroke stays within a frame; anything else
/// folds through Foundation.
public struct FileNameMatcher: Sendable {
    private let folded: String
    private let asciiNeedle: [UInt8]?

    /// A matcher for `text`. Empty text matches every name.
    public init(_ text: String) {
        folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let bytes = Array(text.utf8)
        asciiNeedle = bytes.allSatisfy { $0 < 0x80 } ? bytes.map(Self.lower) : nil
    }

    /// True when every name matches (empty text).
    public var matchesAll: Bool { folded.isEmpty }

    /// Whether `name` contains the text.
    public func matches(_ name: String) -> Bool {
        if folded.isEmpty { return true }
        // SAFETY: the buffer is the name's own UTF-8 storage, valid only inside the closure, and contains lets
        // nothing of it out. Its reads stay in bounds by its loop bounds, not by the subscript (unchecked in
        // release): hay[i] only for startIndex <= i < endIndex, and hay[start + offset] only with
        // offset < n and start + n <= endIndex.
        if let needle = asciiNeedle,
           let result = unsafe name.utf8.withContiguousStorageIfAvailable({ unsafe Self.contains($0, needle) }) ?? nil {
            return result
        }
        return name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(folded)
    }

    /// Byte search; nil when the name is not ASCII (the caller folds instead).
    private static func contains<Bytes: RandomAccessCollection<UInt8>>(_ hay: Bytes, _ needle: [UInt8]) -> Bool?
        where Bytes.Index == Int {
        if hay.contains(where: { $0 >= 0x80 }) { return nil }
        let n = needle.count
        guard n <= hay.count else { return false }
        var start = hay.startIndex
        // Every read below is hay[start + offset] with offset < n, so start + n <= endIndex keeps it in bounds.
        while start + n <= hay.endIndex {
            var matched = true
            for offset in 0..<n where lower(hay[start + offset]) != needle[offset] {
                matched = false
                break
            }
            if matched { return true }
            start += 1
        }
        return false
    }

    private static func lower(_ byte: UInt8) -> UInt8 { byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte }
}
