import CmuxHomeCore
import CoreGraphics
import Foundation
@testable import CmuxHomeRender

/// Transcript fixtures built only through CmuxHomeCore's public API.
@MainActor
enum Fixtures {
    static let me = ParticipantID("user_me")
    static let chief = ParticipantID("agent_chief")
    static let conversation = ConversationID("conv_test")
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return c
    }

    static func message(_ seq: Seq, _ author: ParticipantID, _ text: String, at seconds: TimeInterval? = nil) -> Message {
        Message(id: MessageID("msg_\(seq)"), conversation: conversation, seq: seq, clientMessageID: IdempotencyKey("key_\(seq)"),
                author: author, parts: [.text(text)], createdAt: start.addingTimeInterval(seconds ?? Double(seq) * 30))
    }

    static func items(_ messages: [Message], pending: [PendingIntent] = []) -> [TranscriptItem] {
        TranscriptWindow(messages: messages).items(pending: pending, me: me)
    }

    static func summary(read: [ParticipantID: Seq] = [:]) -> ConversationSummary {
        ConversationSummary(id: conversation,
                            participants: [Participant(id: me, kind: .human, displayName: "Me"),
                                           Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief)],
                            createdAt: start, updatedAt: start, readCursors: read)
    }

    static let shortLines = ["Status?", "Done.", "Looks good. Keep going.", "On it.", "Ship it."]
    static let longLine = "The fleet build finished and two tests failed on the base branch; they are not ours, so I opened a draft "
        + "PR with the plan and asked for a review from the owners of the transport crate."

    /// `count` messages alternating in runs of two, every fifth one long.
    static func conversation(_ count: Int, firstSeq: Seq = 1) -> [Message] {
        (0..<count).map { i in
            let seq = firstSeq + Seq(i)
            let author = (i / 2) % 2 == 0 ? chief : me
            let text = i % 5 == 4 ? longLine : shortLines[i % shortLines.count]
            return message(seq, author, text)
        }
    }

    static func controller(width: CGFloat = 628, height: CGFloat = 1041) -> HomeController {
        let c = HomeController(conversation: conversation, me: me, calendar: calendar, locale: Locale(identifier: "en_US"),
                               now: { start.addingTimeInterval(3600) })
        c.resize(to: CGSize(width: width, height: height))
        return c
    }
}
