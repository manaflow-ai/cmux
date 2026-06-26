import Foundation

struct TextBoxMentionCompletionDetector {
    static func query(in text: String, selectedRange: NSRange) -> TextBoxMentionQuery? {
        guard selectedRange.length == 0,
              selectedRange.location != NSNotFound else {
            return nil
        }

        let nsText = text as NSString
        let cursor = min(max(0, selectedRange.location), nsText.length)
        guard cursor > 0 else { return nil }

        var tokenStart = cursor
        while tokenStart > 0 {
            let previous = nsText.substring(with: NSRange(location: tokenStart - 1, length: 1))
            if previous.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
                break
            }
            tokenStart -= 1
        }

        guard tokenStart < cursor else { return nil }
        let tokenRange = NSRange(location: tokenStart, length: cursor - tokenStart)
        let token = nsText.substring(with: tokenRange)
        guard let trigger = token.first else { return nil }

        let kind: TextBoxMentionKind
        switch trigger {
        case "@":
            kind = .file
        case "/":
            kind = .skill
        case "$":
            kind = .skill
        default:
            return nil
        }

        guard token.allSatisfy({ character in
            character != "[" &&
                character != "]" &&
                character != "(" &&
                character != ")" &&
                character != "<" &&
                character != ">"
        }) else {
            return nil
        }

        let query = String(token.dropFirst())
        return TextBoxMentionQuery(kind: kind, range: tokenRange, query: query, trigger: trigger)
    }
}
