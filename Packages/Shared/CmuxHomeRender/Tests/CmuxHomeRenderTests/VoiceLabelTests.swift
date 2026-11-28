import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

/// The Chief's team speaks in voices (optchat-chief `voice.rs`): a front desk
/// receipt and the Chief's own reply read as two voices of one Chief.
@MainActor
@Suite struct VoiceLabelTests {
    private func names(_ c: HomeController) -> [String] {
        c.scene.model.rows.compactMap { if case .senderName(let n) = $0.spec.kind { n } else { nil } }
    }

    private func desk(_ seq: Seq, _ text: String, at seconds: TimeInterval) -> Message {
        Message(id: MessageID("msg_\(seq)"), conversation: Fixtures.conversation, seq: seq,
                clientMessageID: IdempotencyKey("voice:desk:turn:optchat:\(seq):1"),
                author: Fixtures.chief, parts: [.text(text)], createdAt: Fixtures.start.addingTimeInterval(seconds))
    }

    @Test func aDeskReceiptAndTheChiefsReplyAreTwoLabeledRuns() {
        let messages = [Fixtures.message(1, Fixtures.me, "hello?", at: 0),
                        desk(2, "Got it. The Chief is busy with a turn and reads your message next.", at: 5),
                        Fixtures.message(3, Fixtures.chief, "Done: the sidebar is fixed.", at: 60)]
        let c = Fixtures.controller(height: 800)
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        #expect(names(c) == ["Front desk", "Chief"], "one Chief, two voices, in a one-to-one chat")
        let tails = c.scene.model.rows.map(\.spec).compactMap { $0.partRow?.tail }
        #expect(tails == [true, true, true], "the receipt and the reply each end their own run")
    }

    @Test func theChiefAloneStaysUnlabeledInAOneToOneChat() {
        let messages = [Fixtures.message(1, Fixtures.me, "hello?", at: 0),
                        Fixtures.message(2, Fixtures.chief, "Hi.", at: 5)]
        let c = Fixtures.controller(height: 800)
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        #expect(names(c).isEmpty)
    }

    @Test func onlyAnAgentSpeaksInAVoice() {
        let spoof = Message(id: MessageID("msg_2"), conversation: Fixtures.conversation, seq: 2,
                            clientMessageID: IdempotencyKey("voice:desk:x"), author: ParticipantID("user_bob"),
                            parts: [.text("not the desk")], createdAt: Fixtures.start.addingTimeInterval(5))
        let items = Fixtures.items([desk(1, "Got it.", at: 0), spoof])
        #expect(items.map(RowBuilder.voice) == ["desk", nil])
    }

    @Test func onlyVoiceKeysHaveAVoice() {
        #expect(IdempotencyKey("voice:desk:turn:optchat:4:17").voice == "desk")
        #expect(IdempotencyKey("voice:a7:x").voice == "a7")
        #expect(IdempotencyKey("turn:optchat:4:17").voice == nil)
        #expect(IdempotencyKey("voice::x").voice == nil)
        #expect(IdempotencyKey("voice:Desk:x").voice == nil)
        #expect(IdempotencyKey("voice:desk").voice == nil)
    }
}
