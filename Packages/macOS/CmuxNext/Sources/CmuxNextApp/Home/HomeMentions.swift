import CmuxNextDaemon
import Foundation

/// `@name` mentions in typed text, as text runs naming the participant
/// (plans/cmux-next/home.md section 5: mentions wake agents).
enum HomeMentions {
    static func runs(in text: String, participants: [ConversationParticipant]) -> [ConversationTextRun] {
        let utf16 = Array(text.utf16)
        // Lowercase every name once, and compare each `@` against a window as
        // long as the longest name (plus slack for case mappings that change
        // length), never against the whole rest of the text: that was
        // quadratic in a pasted text full of `@` (cx-9c8m).
        let names = participants.map { ($0, $0.displayName.lowercased()) }.filter { !$0.1.isEmpty }
        guard let longest = names.map(\.1.utf16.count).max() else { return [] }
        let window = longest + 8
        var runs: [ConversationTextRun] = []
        var index = 0
        while index < utf16.count {
            defer { index += 1 }
            guard utf16[index] == UInt16(UInt8(ascii: "@")), index == 0 || isBoundary(utf16[index - 1]) else { continue }
            let upper = min(utf16.count, index + 1 + window)
            let rest = String(decoding: utf16[(index + 1)..<upper], as: UTF16.self).lowercased()
            let match = names
                .filter { rest.hasPrefix($0.1) }
                .max { $0.1.utf16.count < $1.1.utf16.count }
            guard let (participant, name) = match else { continue }
            let end = index + 1 + name.utf16.count
            guard end <= utf16.count, end == utf16.count || isBoundary(utf16[end]) else { continue }
            runs.append(ConversationTextRun(start: index, length: end - index, mention: participant.id))
            index = end - 1
        }
        return runs
    }

    private static func isBoundary(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return true }
        return !CharacterSet.alphanumerics.contains(scalar) && scalar != "_"
    }
}
