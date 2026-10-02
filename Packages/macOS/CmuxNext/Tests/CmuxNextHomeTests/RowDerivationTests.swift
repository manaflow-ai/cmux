@testable import CmuxNextHome
import CoreGraphics
import Foundation
import Testing

struct RowDerivationTests {
    private func message(_ seq: Int, _ author: String, at seconds: Double, parts: [HomePart]? = nil) -> HomeMessage {
        HomeMessage(id: "m\(seq)", seq: seq, clientMsgID: "c\(seq)", authorID: author, parts: parts ?? [.text("hi \(seq)")],
                    createdAt: HomeFixture.base.addingTimeInterval(seconds), delivery: author == HomeFixture.me ? .sent : .none)
    }

    private func rows(_ messages: [HomeMessage], readThrough: Int? = nil) -> [TranscriptRow] {
        var window = TranscriptWindow()
        _ = window.replace(messages, pending: [], newest: messages.last?.seq ?? 0, oldest: 1)
        var layout = TranscriptLayout()
        layout.rebuild(window, context: HomeFixture.context(readThrough: readThrough))
        return layout.rows
    }

    private func tail(_ row: TranscriptRow) -> Bool? {
        switch row.kind {
        case .bubble(_, _, _, let tail, _, _), .work(_, _, _, _, _, let tail), .fallback(_, _, let tail): tail
        default: nil
        }
    }

    @Test func onlyTheLastBubbleOfAGroupHasATail() {
        let me = HomeFixture.me, agent = HomeFixture.agent
        let list = rows([message(1, me, at: 0), message(2, me, at: 20), message(3, me, at: 40), message(4, agent, at: 50),
                         message(5, agent, at: 200)])
        let tails = list.compactMap(tail)
        // 1 2 3 are one group; 4 and 5 are 150 s apart (over the 60 s group window): two groups
        #expect(tails == [false, false, true, true, true])
    }

    @Test func timeSeparatorBeforeTheFirstMessageAndAfterFifteenMinutes() {
        let me = HomeFixture.me
        let list = rows([message(1, me, at: 0), message(2, me, at: 60), message(3, me, at: 60 + 15 * 60 + 1)])
        let separators = list.filter { if case .separator = $0.kind { true } else { false } }
        #expect(separators.count == 2)
        #expect(list.first.map { if case .separator = $0.kind { true } else { false } } == true)
        #expect(separators.allSatisfy { $0.x == ((HomeFixture.geometry.width - $0.width) / 2).rounded() })
    }

    @Test func groupGapIsSmallerThanSenderGap() {
        let me = HomeFixture.me, agent = HomeFixture.agent
        let list = rows([message(1, me, at: 0), message(2, me, at: 10), message(3, agent, at: 20)])
        let bubbles = list.filter(\.isBubbleLike)
        let g = HomeFixture.geometry
        #expect(bubbles[1].gapBefore == g.groupGap)
        #expect(bubbles[2].gapBefore == g.senderGap)
        #expect(bubbles[0].isOutgoing && !bubbles[2].isOutgoing)
        #expect(bubbles[0].x + bubbles[0].width == g.width - g.sideMargin)
        #expect(bubbles[2].x == g.sideMargin)
    }

    @Test func readReceiptUnderMyLatestReadMessageOnly() {
        let me = HomeFixture.me, agent = HomeFixture.agent
        let list = rows([message(1, me, at: 0), message(2, agent, at: 100), message(3, me, at: 200), message(4, me, at: 210)],
                        readThrough: 3)
        let labels = list.compactMap { row -> (String, String?)? in
            if case .label(let text, _, _, _) = row.kind { return (text, row.messageKey) }
            return nil
        }
        // 3 is read; 4 is delivered and newer, so both show (MODEL.md "Derived")
        #expect(labels.map(\.0) == ["Read", "Delivered"])
        #expect(labels.map(\.1) == ["c3", "c4"])
    }

    @Test func retractedWorkAndFallbackRows() {
        let me = HomeFixture.me, agent = HomeFixture.agent
        var retracted = message(2, agent, at: 10, parts: [])
        retracted.retractedAt = HomeFixture.base.addingTimeInterval(20)
        let list = rows([message(1, agent, at: 0, parts: [.work(session: "build", status: .running, preview: "xcodebuild")]),
                         retracted, message(3, me, at: 30, parts: [.fallback("photo.jpg")])])
        #expect(list.contains { if case .work(_, "build", .running, _, "xcodebuild", _) = $0.kind { true } else { false } })
        #expect(list.contains { if case .retracted("Unsent") = $0.kind { true } else { false } })
        #expect(list.contains { if case .fallback(true, "photo.jpg", _) = $0.kind { true } else { false } })
    }

    @Test func reactionsLeaveRoomAboveTheBubble() {
        var reacted = message(2, HomeFixture.agent, at: 100)
        reacted.reactions = [HomeReaction(authorID: HomeFixture.me, kind: "like")]
        let plain = rows([message(1, HomeFixture.me, at: 0), message(2, HomeFixture.agent, at: 100)]).filter(\.isBubbleLike)
        let badged = rows([message(1, HomeFixture.me, at: 0), reacted]).filter(\.isBubbleLike)
        #expect(badged[1].gapBefore == plain[1].gapBefore + HomeFixture.geometry.badgeRoom)
    }
}
