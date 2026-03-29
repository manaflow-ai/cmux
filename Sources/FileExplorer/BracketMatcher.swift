import AppKit

/// Pure utility for finding and highlighting matching bracket pairs.
enum BracketMatcher {

    private static let openBrackets: [Character: Character] = ["(": ")", "{": "}", "[": "]"]
    private static let closeBrackets: [Character: Character] = [")": "(", "}": "{", "]": "["]

    /// Highlight matching brackets at the cursor position in the given text view.
    static func highlightMatchingBrackets(in textView: NSTextView) {
        let string = textView.string
        let position = textView.selectedRange().location
        guard !string.isEmpty else { return }

        let nsString = string as NSString

        // Clear any previous bracket highlights
        let fullRange = NSRange(location: 0, length: nsString.length)
        textView.textStorage?.removeAttribute(.backgroundColor, range: fullRange)

        // Check character at cursor and before cursor
        if let match = findMatch(in: nsString, at: position) {
            applyHighlight(to: textView, at: match.0, and: match.1)
        } else if position > 0, let match = findMatch(in: nsString, at: position - 1) {
            applyHighlight(to: textView, at: match.0, and: match.1)
        }
    }

    /// Find matching bracket starting from the given character position.
    /// Returns (bracketPos, matchPos) or nil.
    private static func findMatch(in string: NSString, at pos: Int) -> (Int, Int)? {
        guard pos >= 0, pos < string.length,
              let scalar = UnicodeScalar(string.character(at: pos)) else { return nil }
        let char = Character(scalar)

        if let closing = openBrackets[char] {
            // Scan forward for matching close
            if let matchPos = scanForward(in: string, from: pos + 1, open: char, close: closing) {
                return (pos, matchPos)
            }
        } else if let opening = closeBrackets[char] {
            // Scan backward for matching open
            if let matchPos = scanBackward(in: string, from: pos - 1, open: opening, close: char) {
                return (pos, matchPos)
            }
        }
        return nil
    }

    private static func scanForward(in string: NSString, from start: Int, open: Character, close: Character) -> Int? {
        var depth = 1
        for i in start..<string.length {
            guard let scalar = UnicodeScalar(string.character(at: i)) else { continue }
            let c = Character(scalar)
            if c == open { depth += 1 }
            else if c == close { depth -= 1 }
            if depth == 0 { return i }
        }
        return nil
    }

    private static func scanBackward(in string: NSString, from start: Int, open: Character, close: Character) -> Int? {
        var depth = 1
        var i = start
        while i >= 0 {
            guard let scalar = UnicodeScalar(string.character(at: i)) else { i -= 1; continue }
            let c = Character(scalar)
            if c == close { depth += 1 }
            else if c == open { depth -= 1 }
            if depth == 0 { return i }
            i -= 1
        }
        return nil
    }

    private static func applyHighlight(to textView: NSTextView, at pos1: Int, and pos2: Int) {
        let isDark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            || textView.window == nil
        let highlightColor = isDark
            ? NSColor.white.withAlphaComponent(0.15)
            : NSColor.black.withAlphaComponent(0.1)

        textView.textStorage?.addAttribute(
            .backgroundColor, value: highlightColor,
            range: NSRange(location: pos1, length: 1)
        )
        textView.textStorage?.addAttribute(
            .backgroundColor, value: highlightColor,
            range: NSRange(location: pos2, length: 1)
        )
    }
}
