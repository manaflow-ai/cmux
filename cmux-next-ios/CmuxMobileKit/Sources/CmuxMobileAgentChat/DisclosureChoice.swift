/// A row that opens on its own (a live thought shows its last lines) until
/// the person taps it: from then on their choice holds, so a tap always
/// closes what is open. A live thought used to keep its text on screen
/// after a tap with the chevron turned to closed.
struct DisclosureChoice: Equatable {
    /// The person's choice; nil follows `automatic`.
    private(set) var chosen: Bool?

    func isOpen(automatic: Bool) -> Bool { chosen ?? automatic }

    mutating func toggle(automatic: Bool) {
        chosen = !isOpen(automatic: automatic)
    }
}

extension DisclosureChoice {
    /// The end of `text` that fits three lines: its last three lines, and of a long last
    /// line only its end, cut at a word ("…" says text comes before it).
    static func liveTail(of text: String, lines: Int = 3, characters: Int = 240) -> String {
        // Only the end is read: a long live thought is split again on every chunk.
        let window = text.suffix(characters * 2)
        let parts = window.split(separator: "\n", omittingEmptySubsequences: true)
        let kept = parts.suffix(lines)
        var tail = kept.joined(separator: "\n")
        var cut = parts.count > kept.count || window.startIndex != text.startIndex
        if tail.count > characters {
            let end = tail.suffix(characters)
            tail = String(end.firstIndex(where: \.isWhitespace).map { end[$0...].drop(while: \.isWhitespace) } ?? end)
            cut = true
        }
        return cut ? "…" + tail : tail
    }
}
