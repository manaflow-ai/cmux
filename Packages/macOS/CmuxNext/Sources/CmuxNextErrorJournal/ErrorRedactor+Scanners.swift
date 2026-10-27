import Foundation

/// The two key finders of ``ErrorRedactor`` as single passes over UTF-16 (p10-stability-191). Each
/// finds what its former pattern found, in the same order; as regexes, both restarted a scan to the
/// end of a run from every position inside it (`a-a-a-…`, `((((…`), quadratic in the run.
extension ErrorRedactor {
    /// One `key:` / `key=` anchor: the key, and where the separator and the white space after it end.
    struct AssignmentAnchor: Equatable {
        var key: NSRange
        var end: Int
    }

    /// The anchors `\b([A-Za-z_][A-Za-z0-9_-]*)((?:(?:\\+)?["'])?\s*[:=]\s*)` matched: leftmost
    /// first, none overlapping. Every start inside one `[A-Za-z0-9_-]` run reaches the run's end
    /// (no run character can begin the separator), so a run either gives one anchor, from its first
    /// start, or none: one look at the run's end decides.
    static func assignmentAnchors(in units: [UInt16]) -> [AssignmentAnchor] {
        var anchors: [AssignmentAnchor] = []
        var index = 0
        while index < units.count {
            guard isKeyRunUnit(units[index]) else {
                index += 1
                continue
            }
            var runEnd = index
            while runEnd < units.count, isKeyRunUnit(units[runEnd]) { runEnd += 1 }
            let start = (index..<runEnd).first { position in
                isKeyStartUnit(units[position]) && (position == 0 || !isWordUnit(units[position - 1]))
            }
            if let start, let end = separatorEnd(in: units, from: runEnd) {
                anchors.append(AssignmentAnchor(key: NSRange(location: start, length: runEnd - start), end: end))
                index = end
            } else {
                index = runEnd
            }
        }
        return anchors
    }

    /// Where `(?:(?:\\+)?["'])?\s*[:=]\s*` matched at `start`, or nil.
    static func separatorEnd(in units: [UInt16], from start: Int) -> Int? {
        var index = start
        var quote = start
        while quote < units.count, units[quote] == 92 { quote += 1 }
        if quote < units.count, units[quote] == 34 || units[quote] == 39 { index = quote + 1 }
        while index < units.count, isPatternWhitespace(units[index]) { index += 1 }
        guard index < units.count, units[index] == 58 || units[index] == 61 else { return nil }
        index += 1
        while index < units.count, isPatternWhitespace(units[index]) { index += 1 }
        return index
    }

    /// The keys the zero-width `(?=(^|[?#&;\s="'=(:,])([^=?&#;\s"']+)=)` found, one per position it
    /// matched, in order: a key starts at the text's start or after a delimiter and runs to `=`. A
    /// key run is the longest run of key units (`=` is not one), so `stop` (the first non-key unit
    /// at or after each position, from one backward pass) decides each position at once.
    static func queryKeys(in units: [UInt16]) -> [NSRange] {
        let count = units.count
        guard count > 0 else { return [] }
        var stop = [Int](repeating: count, count: count + 1)
        for position in stride(from: count - 1, through: 0, by: -1) {
            stop[position] = isQueryKeyUnit(units[position]) ? stop[position + 1] : position
        }
        func key(from start: Int) -> NSRange? {
            guard start < count, stop[start] > start, stop[start] < count, units[stop[start]] == 61 else { return nil }
            return NSRange(location: start, length: stop[start] - start)
        }
        var keys: [NSRange] = []
        for position in 0..<count {
            if position == 0, let found = key(from: 0) {
                keys.append(found)
            } else if isQueryDelimiterUnit(units[position]), let found = key(from: position + 1) {
                keys.append(found)
            }
        }
        return keys
    }

    // MARK: - Unit classes

    /// `[A-Za-z0-9_-]`.
    static func isKeyRunUnit(_ unit: UInt16) -> Bool {
        isKeyStartUnit(unit) || (unit >= 48 && unit <= 57) || unit == 45
    }

    /// `[A-Za-z_]`.
    static func isKeyStartUnit(_ unit: UInt16) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95
    }

    /// ICU's `\w` (letters, marks, decimal digits, connector punctuation, ZWNJ, ZWJ), which `\b`
    /// tests. Half of a surrogate pair counts as not a word unit.
    static func isWordUnit(_ unit: UInt16) -> Bool {
        if unit < 128 { return isKeyStartUnit(unit) || (unit >= 48 && unit <= 57) }
        if unit == 0x200C || unit == 0x200D { return true }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        let properties = scalar.properties
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .connectorPunctuation: return true
        default: return properties.isAlphabetic
        }
    }

    /// ICU's `\s`: `[\t\n\f\r\p{Z}]`.
    static func isPatternWhitespace(_ unit: UInt16) -> Bool {
        if unit == 9 || unit == 10 || unit == 12 || unit == 13 || unit == 32 { return true }
        guard unit >= 128, let scalar = Unicode.Scalar(unit) else { return false }
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    /// `[^=?&#;\s"']`.
    static func isQueryKeyUnit(_ unit: UInt16) -> Bool {
        !(unit == 61 || unit == 63 || unit == 38 || unit == 35 || unit == 59 || unit == 34 || unit == 39
            || isPatternWhitespace(unit))
    }

    /// `[?#&;\s="'(:,]`.
    static func isQueryDelimiterUnit(_ unit: UInt16) -> Bool {
        unit == 63 || unit == 35 || unit == 38 || unit == 59 || unit == 61 || unit == 34 || unit == 39
            || unit == 40 || unit == 58 || unit == 44 || isPatternWhitespace(unit)
    }
}
