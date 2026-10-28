import Foundation

/// The terminal's text as VoiceOver reads it: the viewport's rows, with the line table the
/// NSAccessibility text attributes of ``TerminalSurfaceView`` answer from. Offsets and lengths are
/// UTF-16 units, as `NSRange` and AXNumberOfCharacters count them (not Swift characters).
nonisolated struct TerminalAccessibleText: Equatable, Sendable {
    /// The text (AXValue).
    let string: String
    /// Its length in UTF-16 units (AXNumberOfCharacters).
    let length: Int
    /// The UTF-16 offset where each line starts; the first is 0, then one after each newline.
    private let lineStarts: [Int]

    init(_ string: String) {
        self.string = string
        var starts = [0]
        var offset = 0
        for unit in string.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        lineStarts = starts
        length = offset
    }

    /// The line that holds the UTF-16 offset `index` (AXLineForIndex), clamped to the text.
    func line(for index: Int) -> Int {
        let index = min(max(index, 0), length)
        // The last line start at or before `index`.
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= index { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The range of `line`, its newline included (AXRangeForLine); `NSNotFound` past the last line.
    func range(forLine line: Int) -> NSRange {
        guard lineStarts.indices.contains(line) else { return NSRange(location: NSNotFound, length: 0) }
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : length
        return NSRange(location: lineStarts[line], length: end - lineStarts[line])
    }

    /// The text in `range` (AXStringForRange); nil when the range is not inside the text.
    func string(for range: NSRange) -> String? {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location + range.length <= length else { return nil }
        return (string as NSString).substring(with: range)
    }
}

/// One viewport read kept for ``lifetime``: VoiceOver asks for a text area's value, count, visible
/// range and lines as separate requests in a burst, and each would otherwise read the viewport under
/// Ghostty's terminal lock again. Upstream Ghostty keeps its screen text 500 ms for the same reason
/// (SurfaceView_AppKit.swift, `cachedScreenContents`); a shorter life keeps new output current.
struct TerminalAccessibleTextCache {
    static let lifetime: Duration = .milliseconds(250)

    private var kept: (text: TerminalAccessibleText, readAt: ContinuousClock.Instant)?

    /// The kept text while it is younger than ``lifetime`` at `now`, else `read()`'s text (nil reads
    /// as empty), kept from `now`.
    mutating func text(now: ContinuousClock.Instant, read: () -> String?) -> TerminalAccessibleText {
        if let kept, kept.readAt <= now, now - kept.readAt < Self.lifetime { return kept.text }
        let text = TerminalAccessibleText(read() ?? "")
        kept = (text, now)
        return text
    }
}
