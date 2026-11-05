@testable import CmuxHomeCore
import Foundation
import Testing

/// ``TranscriptWindow/trimOlder(keepingNewest:preserving:)``: the bound a resting reader puts
/// on a conversation's loaded window, and that the dropped history pages back in.
@Suite struct TranscriptWindowTrimTests {
    private static let conversation = ConversationID("c")

    private static func message(_ seq: Int, replyTo: Int? = nil, root: Int? = nil) -> Message {
        Message(id: MessageID("m\(seq)"), conversation: conversation, seq: Seq(seq), clientMessageID: IdempotencyKey("k\(seq)"),
                author: ParticipantID("p"), parts: [.text("\(seq)")], createdAt: Date(timeIntervalSince1970: TimeInterval(seq)),
                replyTo: replyTo.map { PartRef(message: MessageID("m\($0)")) }, threadRoot: root.map { MessageID("m\($0)") })
    }

    private static func window(_ range: ClosedRange<Int>) -> TranscriptWindow {
        TranscriptWindow(messages: range.map { message($0) })
    }

    @Test func keepsTheNewestAndMarksOlderHistoryToLoad() {
        var window = Self.window(1...200)
        #expect(window.reachedStart)
        let trimmed = window.trimOlder(keepingNewest: 50)
        #expect(trimmed)
        #expect(window.messages.map(\.seq) == (151...200).map { Seq($0) })
        #expect(!window.reachedStart)
        // The dropped history pages back in where it was cut.
        let joined = window.prepend((101...150).map { Self.message($0) }, reachedStart: false)
        #expect(joined)
        #expect(window.messages.first?.seq == 101)
    }

    @Test func belowTheCountItKeepsEverything() {
        var window = Self.window(1...40)
        let trimmed = window.trimOlder(keepingNewest: 50)
        #expect(!trimmed)
        #expect(window.messages.count == 40)
        #expect(window.reachedStart)
    }

    @Test func keepsWhatKeptMessagesAnswerAndWhatTheViewHoldsOpen() {
        var window = TranscriptWindow(messages: (1...100).map { Self.message($0) } + [Self.message(101, replyTo: 30)])
        let answered = window.trimOlder(keepingNewest: 10)
        #expect(answered)
        #expect(window.messages.first?.seq == 30)
        var threaded = TranscriptWindow(messages: (1...100).map { Self.message($0) } + [Self.message(101, root: 20)])
        let threadedTrimmed = threaded.trimOlder(keepingNewest: 10)
        #expect(threadedTrimmed)
        #expect(threaded.messages.first?.seq == 20)
        var held = Self.window(1...100)
        let heldTrimmed = held.trimOlder(keepingNewest: 10, preserving: [MessageID("m5")])
        #expect(heldTrimmed)
        #expect(held.messages.first?.seq == 5)
    }

    @Test func whatItKeepsNeverHoldsTheWindowAboveTheLimit() {
        // The newest message answers the very first one: keeping it would stop the bound for good.
        var window = TranscriptWindow(messages: (1...300).map { Self.message($0) } + [Self.message(301, replyTo: 1)])
        let trimmed = window.trimOlder(keepingNewest: 100, atMost: 150)
        #expect(trimmed)
        #expect(window.messages.count == 150)
        #expect(window.messages.last?.seq == 301)
    }
}
