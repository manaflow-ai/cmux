public import CmuxNextDaemon
import CmuxNextHomeModel
import Foundation

/// `@name` mentions in typed text, as text runs naming the participant
/// (plans/cmux-next/home.md section 5: mentions wake agents). The rule is Rust's
/// (cmux-home-rules `compose.mentions.runs`, UTF-16 offsets).
public enum HomeMentions {
    public static func runs(in text: String, participants: [ConversationParticipant]) -> [ConversationTextRun] {
        guard text.utf16.contains(UInt16(UInt8(ascii: "@"))) else { return [] }
        let request = Request(text: text, participants: participants.map { Named(id: $0.id, displayName: $0.displayName) })
        let runs: [Run] = HomeComposeRules.call("mentions.runs", request, fallback: [])
        return runs.map { ConversationTextRun(start: $0.start, length: $0.length, mention: $0.mention) }
    }

    private struct Named: Encodable {
        var id: String
        var displayName: String
    }

    private struct Request: Encodable {
        var text: String
        var participants: [Named]
    }

    private struct Run: Decodable {
        var start: Int
        var length: Int
        var mention: String
    }
}
