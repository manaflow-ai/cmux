/// Cuts one dictation session's growing text into finished sentences for the room.
///
/// A dictation update carries the session's whole text so far, and its last words may still be
/// rewritten. A sentence is finished once a later sentence has started after its end mark; a long
/// run with no end mark is cut at a word boundary. ``finish(_:)`` sends whatever is left when the
/// session ends.
///
/// ```swift
/// var splitter = VoiceRoomLineSplitter()
/// splitter.feed("Ship it. Then", level: 0.4)   // [Ship it.]
/// splitter.finish("Ship it. Then we test.")    // [Then we test.]
/// ```
public struct VoiceRoomLineSplitter: Sendable {
    private static let endMarks: Set<Character> = [".", "?", "!", "。", "？", "！"]

    /// Characters of the session's text already sent.
    private var sent = 0
    private var peak: Float = 0
    private let longRun: Int

    /// - Parameter longRun: A run of this many characters with no end mark is cut at its last space.
    public init(longRun: Int = 220) {
        self.longRun = longRun
    }

    /// The finished sentences in `text` that were not sent yet.
    ///
    /// - Parameters:
    ///   - text: The session's whole text so far.
    ///   - level: The mic level now.
    /// - Returns: Lines to send, oldest first.
    public mutating func feed(_ text: String, level: Float) -> [VoiceRoomLine] {
        peak = max(peak, level)
        let characters = Array(text)
        guard sent < characters.count else { return [] }
        let pending = characters[sent...]
        var cut: Int?
        var index = pending.startIndex
        while index < pending.endIndex {
            if Self.endMarks.contains(pending[index]) {
                let rest = pending[(index + 1)...]
                if rest.contains(where: { !$0.isWhitespace && !Self.endMarks.contains($0) }) { cut = index + 1 }
            }
            index += 1
        }
        if cut == nil, pending.count >= longRun, let space = pending.lastIndex(where: \.isWhitespace), space > sent {
            cut = space
        }
        guard let cut else { return [] }
        let lines = take(characters, through: cut)
        // The words after the cut were heard in this same update, so its level counts for them too.
        peak = level
        return lines
    }

    /// Everything not sent yet, at the end of the session; the splitter starts over.
    ///
    /// - Parameter text: The session's final text.
    /// - Returns: The last line, or nothing when all was sent.
    public mutating func finish(_ text: String) -> [VoiceRoomLine] {
        let characters = Array(text)
        let lines = sent < characters.count ? take(characters, through: characters.count) : []
        sent = 0
        peak = 0
        return lines
    }

    private mutating func take(_ characters: [Character], through end: Int) -> [VoiceRoomLine] {
        let text = String(characters[sent..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        sent = end
        let level = peak
        peak = 0
        return text.isEmpty ? [] : [VoiceRoomLine(kind: .speech, text: text, level: level)]
    }
}
