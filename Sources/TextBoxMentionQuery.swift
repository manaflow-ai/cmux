import Foundation

struct TextBoxMentionQuery: Equatable, Sendable {
    let kind: TextBoxMentionKind
    let location: Int
    let length: Int
    let query: String
    let trigger: Character

    var range: NSRange {
        NSRange(location: location, length: length)
    }

    init(kind: TextBoxMentionKind, range: NSRange, query: String, trigger: Character? = nil) {
        self.kind = kind
        location = range.location
        length = range.length
        self.query = query
        self.trigger = trigger ?? kind.defaultTrigger
    }
}
