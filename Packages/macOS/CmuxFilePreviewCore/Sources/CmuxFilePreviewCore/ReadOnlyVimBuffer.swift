import Foundation

/// Immutable text coordinates used by the preview's navigation interpreter.
struct ReadOnlyVimBuffer {
    let text: NSString

    init(_ source: String) {
        text = source as NSString
    }

    var length: Int { text.length }
    func clamp(_ offset: Int) -> Int {
        guard length > 0 else { return 0 }
        let boundary = text.rangeOfComposedCharacterSequence(at: min(max(0, offset), length - 1)).location
        return isNewline(boundary) ? last(boundary) : boundary
    }
    func next(_ offset: Int) -> Int {
        guard offset < length else { return length }
        return NSMaxRange(text.rangeOfComposedCharacterSequence(at: max(0, offset)))
    }
    func previous(_ offset: Int) -> Int {
        guard offset > 0 else { return 0 }
        return text.rangeOfComposedCharacterSequence(at: min(offset, length) - 1).location
    }
    func line(_ offset: Int) -> NSRange {
        text.lineRange(for: NSRange(location: min(max(0, offset), length), length: 0))
    }
    func end(_ offset: Int) -> Int {
        let range = line(offset)
        var end = NSMaxRange(range)
        while end > range.location, isNewline(previous(end)) { end = previous(end) }
        return end
    }
    func last(_ offset: Int) -> Int {
        let start = line(offset).location
        return max(start, previous(end(offset)))
    }
    func firstNonblank(_ offset: Int) -> Int {
        var index = line(offset).location
        let lineEnd = end(offset)
        while index < lineEnd, character(index).allSatisfy({ $0 == " " || $0 == "\t" }) {
            index = next(index)
        }
        return min(index, last(offset))
    }
    func character(_ offset: Int) -> String {
        guard offset < length else { return "" }
        return text.substring(with: text.rangeOfComposedCharacterSequence(at: offset))
    }
    func isNewline(_ offset: Int) -> Bool {
        !character(offset).isEmpty && character(offset).unicodeScalars.allSatisfy(CharacterSet.newlines.contains)
    }
    func wordClass(_ offset: Int, big: Bool) -> Int {
        let value = character(offset)
        if value.isEmpty || value.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains) { return 0 }
        if big || value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) { return 1 }
        return 2
    }
    func word(_ offset: Int, direction: Int, ending: Bool, big: Bool) -> Int {
        var index = offset
        if direction < 0 {
            index = previous(index)
            while index > 0, wordClass(index, big: big) == 0 { index = previous(index) }
            let kind = wordClass(index, big: big)
            while index > 0, wordClass(previous(index), big: big) == kind { index = previous(index) }
        } else if ending {
            index = next(index)
            while index < length, wordClass(index, big: big) == 0 { index = next(index) }
            let kind = wordClass(index, big: big)
            while next(index) < length, wordClass(next(index), big: big) == kind { index = next(index) }
        } else {
            let kind = wordClass(index, big: big)
            while index < length, wordClass(index, big: big) == kind { index = next(index) }
            while index < length, wordClass(index, big: big) == 0 { index = next(index) }
        }
        return clamp(index)
    }
    func vertical(_ offset: Int, delta: Int, column: Int) -> Int {
        var target = line(offset).location
        for _ in 0..<abs(delta) {
            let candidate = delta < 0 ? line(previous(target)).location : NSMaxRange(line(target))
            if candidate == target || candidate >= length { break }
            target = candidate
        }
        let lastColumn = last(target)
        for _ in 0..<column {
            let candidate = next(target)
            if candidate > lastColumn { break }
            target = candidate
        }
        return target
    }
    func column(_ offset: Int) -> Int {
        var position = line(offset).location
        var result = 0
        while position < offset { position = next(position); result += 1 }
        return result
    }
}
