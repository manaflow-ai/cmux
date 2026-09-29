/// A precomputed, Finder-like sort key for a file name.
///
/// Comparison is case-insensitive and numeric-aware, so `file9` sorts before
/// `file10`, like `localizedStandardCompare`. Building the key once per entry
/// and comparing bytes is what keeps sorting a 50,000-entry directory to tens
/// of milliseconds; `localizedStandardCompare` inside the sort comparator costs
/// hundreds.
struct FileTreeNameCollationKey: Sendable {
    private let folded: ContiguousArray<UInt8>
    private let original: ContiguousArray<UInt8>

    /// Creates the key for one file name.
    /// - Parameter name: The displayed file name.
    init(_ name: String) {
        folded = ContiguousArray(name.lowercased().utf8)
        original = ContiguousArray(name.utf8)
    }

    /// Orders two keys: folded natural order first, raw bytes as the tie-break
    /// so the order is total and stable across runs.
    /// - Returns: A negative value, zero or a positive value.
    func compare(_ other: FileTreeNameCollationKey) -> Int {
        let primary = Self.naturalCompare(folded, other.folded)
        if primary != 0 { return primary }
        return Self.byteCompare(original, other.original)
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }

    private static func naturalCompare(_ lhs: ContiguousArray<UInt8>, _ rhs: ContiguousArray<UInt8>) -> Int {
        var i = 0
        var j = 0
        let lhsCount = lhs.count
        let rhsCount = rhs.count
        while i < lhsCount && j < rhsCount {
            let a = lhs[i]
            let b = rhs[j]
            if isDigit(a) && isDigit(b) {
                // Compare the digit runs as numbers: skip leading zeros, then
                // a longer run is larger, then compare digit by digit.
                var iStart = i
                var jStart = j
                while iStart < lhsCount && lhs[iStart] == 48 { iStart += 1 }
                while jStart < rhsCount && rhs[jStart] == 48 { jStart += 1 }
                var iEnd = iStart
                var jEnd = jStart
                while iEnd < lhsCount && isDigit(lhs[iEnd]) { iEnd += 1 }
                while jEnd < rhsCount && isDigit(rhs[jEnd]) { jEnd += 1 }
                let lengthDelta = (iEnd - iStart) - (jEnd - jStart)
                if lengthDelta != 0 { return lengthDelta }
                var p = iStart
                var q = jStart
                while p < iEnd {
                    if lhs[p] != rhs[q] { return Int(lhs[p]) - Int(rhs[q]) }
                    p += 1
                    q += 1
                }
                // Equal values: fewer leading zeros first ("1" before "01").
                let zeroDelta = (iStart - i) - (jStart - j)
                if zeroDelta != 0 { return zeroDelta }
                i = iEnd
                j = jEnd
                continue
            }
            if a != b { return Int(a) - Int(b) }
            i += 1
            j += 1
        }
        return (lhsCount - i) - (rhsCount - j)
    }

    private static func byteCompare(_ lhs: ContiguousArray<UInt8>, _ rhs: ContiguousArray<UInt8>) -> Int {
        let count = min(lhs.count, rhs.count)
        var index = 0
        while index < count {
            if lhs[index] != rhs[index] { return Int(lhs[index]) - Int(rhs[index]) }
            index += 1
        }
        return lhs.count - rhs.count
    }
}
