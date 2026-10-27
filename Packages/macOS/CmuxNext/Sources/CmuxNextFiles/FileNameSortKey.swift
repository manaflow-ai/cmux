import Foundation

/// A name's position in Finder's order, computed once so a sort compares bytes.
///
/// Finder orders names with `localizedStandardCompare`: case- and
/// accent-insensitive, digit runs by value ("file 2" before "file 10"),
/// punctuation before digits before letters. Calling it in a sort's
/// comparator costs ~400 ms for 100 000 names (PARITY.md, baseline). This key
/// gives the same primary order with one pass per name and a `memcmp` per
/// comparison:
///
/// - letters fold to lowercase without accents (ASCII without any Foundation call);
/// - ASCII punctuation maps below digits in the ICU root order (`_ - , ; : ! ? . ' " ( ) [ ] { } @ * / \ & # % ` ^ + < = > | ~ $`);
/// - each digit run becomes a marker, its length without leading zeros, then the digits.
///
/// Names whose keys tie (case or accent only) fall back to the raw name, so
/// the order is total and stable.
public struct FileNameSortKey: Sendable, Hashable, Comparable {
    /// The encoded key.
    public let bytes: [UInt8]

    /// The key of `name`.
    public init(_ name: String) {
        var out: [UInt8] = []
        out.reserveCapacity(name.utf8.count + 4)
        if name.utf8.allSatisfy({ $0 < 0x80 }) {
            Self.encode(name.utf8, into: &out)
        } else {
            let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            Self.encode(folded.utf8, into: &out)
        }
        bytes = out
    }

    /// A key made of raw bytes (composite keys such as Kind order).
    init(bytes: [UInt8]) { self.bytes = bytes }

    public static func < (lhs: FileNameSortKey, rhs: FileNameSortKey) -> Bool {
        lhs.compare(rhs) < 0
    }

    /// Negative, zero or positive as `self` sorts before, with, or after `other`.
    public func compare(_ other: FileNameSortKey) -> Int {
        // SAFETY: `a` and `b` are the two keys' own storage, valid only inside these closures, which let no pointer
        // out; memcmp reads `common` bytes from the start of each, and common is at most either buffer's count.
        unsafe bytes.withUnsafeBufferPointer { a in
            unsafe other.bytes.withUnsafeBufferPointer { b in
                let common = unsafe min(a.count, b.count)
                if common > 0, let pa = unsafe a.baseAddress, let pb = unsafe b.baseAddress {
                    let r = unsafe memcmp(pa, pb, common)
                    if r != 0 { return Int(r) }
                }
                return unsafe a.count - b.count
            }
        }
    }

    /// Digit runs start with this byte, above every punctuation byte and below letters.
    private static let digitMarker: UInt8 = 0x40

    /// ASCII punctuation in ICU root collation order, mapped to 0x02...
    private static let punctuationRank: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 128)
        let order = Array("_-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$".utf8)
        for (index, byte) in order.enumerated() { table[Int(byte)] = UInt8(0x02 + index) }
        table[0x20] = 0x01 // space
        table[0x09] = 0x01 // tab
        return table
    }()

    private static func encode(_ utf8: some Collection<UInt8>, into out: inout [UInt8]) {
        var digits: [UInt8] = []
        func flushDigits() {
            guard !digits.isEmpty else { return }
            var start = 0
            while start < digits.count - 1, digits[start] == 0x30 { start += 1 }
            let significant = digits[start...]
            out.append(digitMarker)
            out.append(UInt8(min(significant.count, 0xFF)))
            out.append(contentsOf: significant)
            digits.removeAll(keepingCapacity: true)
        }
        for byte in utf8 {
            if byte >= 0x30, byte <= 0x39 { digits.append(byte); continue }
            flushDigits()
            switch byte {
            case 0x41...0x5A: out.append(byte + 0x20)
            case 0x61...0x7A: out.append(byte)
            case 0..<0x80:
                let rank = punctuationRank[Int(byte)]
                out.append(rank == 0 ? 0x01 : rank)
            default: out.append(byte) // folded non-ASCII UTF-8 sorts after ASCII letters
            }
        }
        flushDigits()
    }
}
