import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// A Chief turn that ends without a reply posts a done marker: one `work` part naming its acpmux
/// turn session (`optchat-<home>-<line>`, optchat-chief `brain/turns.rs`). The marker settles the
/// messages the turn answered; it is no bubble. Home once drew its session name as the Chief's
/// text (Lawrence 2026-10-21: "i randomly see optchat-2e448bc2-8525 in the chat that u send").
@Suite struct HomeWorkMarkerTests {
    static let base = Date(timeIntervalSince1970: 1_800_000_000)
    static let chief = ParticipantID("agent_mux")
    static let session = "optchat-2e448bc2-8525"

    static var summary: ConversationSummary {
        let people = [CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief)]
        return ConversationSummary(id: ConversationID("c"), title: "Chief", participants: people, lastSeq: 1,
                                   createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
    }

    static func item(_ parts: [MessagePart]) -> TranscriptItem {
        TranscriptItem(key: IdempotencyKey("turn:optchat:8525:202610211810531640700"), seq: Seq(1), author: chief,
                       parts: parts, createdAt: base, delivery: .committed, messageID: MessageID("m"))
    }

    static func shownText(_ message: MessagesLabHome.Message) -> String {
        message.parts.compactMap { if case let .text(text, _) = $0 { text } else { nil } }.joined(separator: "\n")
    }

    @Test func aDoneMarkerDrawsNoBubble() {
        let work = WorkRef(session: Self.session, title: Self.session, status: .done)
        let message = HomeMapping.message(Self.item([.work(work)]), aliases: [:], me: ParticipantID("user_local"),
                                          summary: Self.summary)
        #expect(!Self.shownText(message).contains(Self.session))
        // Kept (its seq still moves the read cursor), never drawn.
        #expect(message.deletedAt != nil)
    }

    @Test func aWorkPartNeverReadsAsItsSessionName() {
        let work = WorkRef(session: Self.session, title: Self.session, status: .done)
        #expect(!MessagePart.work(work).plainText.contains(Self.session))
        #expect(!Self.item([.work(work)]).plainText.contains(Self.session))
    }

    @Test func aWorkPartWithAPreviewShowsThePreview() {
        let work = WorkRef(session: Self.session, title: Self.session, status: .done, preview: "Landed 3 commits")
        let message = HomeMapping.message(Self.item([.work(work)]), aliases: [:], me: ParticipantID("user_local"),
                                          summary: Self.summary)
        #expect(Self.shownText(message) == "Landed 3 commits")
        #expect(message.deletedAt == nil)
    }

    @Test func textBesideAMarkerStillShows() {
        let work = WorkRef(session: Self.session, title: Self.session, status: .done)
        let message = HomeMapping.message(Self.item([.text("Done."), .work(work)]), aliases: [:],
                                          me: ParticipantID("user_local"), summary: Self.summary)
        #expect(Self.shownText(message) == "Done.")
        #expect(message.deletedAt == nil)
    }
}
